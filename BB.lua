local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local TeleportService = game:GetService("TeleportService")
local TweenService = game:GetService("TweenService")

local LocalPlayer = Players.LocalPlayer
local Networking = require(ReplicatedStorage:WaitForChild("SharedModules"):WaitForChild("Networking"))
local Gardens = workspace:WaitForChild("Gardens")

local TARGET_OWNER_NAME = { "quut16pkbn34", "Honlnwzag2g", "Honlnwzag2g" }
local TARGET_PLANT_NAME = "Dragon's Breath"
local SPRINKLER_NAME = "Super Sprinkler"
local WATERING_CAN_NAME = "Super Watering Can"
local WATER_INTERVAL = 15
local SPRINKLER_CHECK_INTERVAL = 1
local REJOIN_RETRY_DELAY = 1
local TOOL_WAIT_TIMEOUT = 8
local CHARACTER_WAIT_TIMEOUT = 15
local RESPAWN_GRACE_SECONDS = 5
local RESPAWN_STAND_WAIT_SECONDS = 115
local TWEEN_REACHED_DISTANCE = 2
local TWEEN_MAX_SECONDS_PER_MOVE = 45
local TWEEN_OFFSET_DISTANCE = 0.9
local PLACE_OFFSET_DISTANCE = 2
local LOG_PREFIX = "[QuutDragonBreathSuperLoop]"

if _G.QuutDragonBreathSuperLoop then
	_G.QuutDragonBreathSuperLoop.Running = false
	for _, connection in ipairs(_G.QuutDragonBreathSuperLoop.Connections or {}) do
		pcall(function()
			connection:Disconnect()
		end)
	end
end

local State = {
	Running = true,
	Rejoining = false,
	Connections = {},
	TargetPlot = nil,
	TargetPlant = nil,
	TargetPosition = nil,
	TweenPosition = nil,
	SelectedOwnerName = nil,
	LastStatus = "",
	ResetToken = 0,
	ResumeAfter = 0,
	StandWaitUntil = 0,
}
_G.QuutDragonBreathSuperLoop = State

local function log(...)
	print(LOG_PREFIX, ...)
end

local function setStatus(message)
	message = tostring(message or "")
	if State.LastStatus ~= message then
		State.LastStatus = message
		log(message)
	end
end

local function normalize(value)
	return tostring(value or ""):lower():gsub("%s+", ""):gsub("[^%w]", "")
end

local function normalizedContains(value, wanted)
	local normalized = normalize(value)
	wanted = normalize(wanted)

	return normalized ~= "" and wanted ~= "" and (normalized == wanted or normalized:find(wanted, 1, true) ~= nil)
end

local function getTargetOwnerNames()
	if type(TARGET_OWNER_NAME) == "table" then
		return TARGET_OWNER_NAME
	end

	return { TARGET_OWNER_NAME }
end

local function getActiveOwnerNames()
	if type(State.SelectedOwnerName) == "string" and State.SelectedOwnerName ~= "" then
		return { State.SelectedOwnerName }
	end

	return getTargetOwnerNames()
end

local function getOwnerLabel()
	if type(State.SelectedOwnerName) == "string" and State.SelectedOwnerName ~= "" then
		return State.SelectedOwnerName
	end

	return table.concat(getTargetOwnerNames(), ", ")
end

local function lockSelectedOwner(ownerName)
	ownerName = tostring(ownerName or "")
	if ownerName == "" or State.SelectedOwnerName then
		return
	end

	State.SelectedOwnerName = ownerName
	log("selected owner:", ownerName)
end

local function rejoin(reason)
	if State.Rejoining then
		return
	end

	State.Rejoining = true
	log("rejoining:", tostring(reason or "requested"))

	task.spawn(function()
		while State.Running do
			pcall(function()
				TeleportService:Teleport(game.PlaceId, LocalPlayer)
			end)
			task.wait(REJOIN_RETRY_DELAY)
		end
	end)
end

local function connect(signal, callback)
	local connection = signal:Connect(callback)
	table.insert(State.Connections, connection)
	return connection
end

local function resetLogic(reason)
	State.ResetToken += 1
	State.TargetPlot = nil
	State.TargetPlant = nil
	State.TargetPosition = nil
	State.TweenPosition = nil
	State.LastStatus = ""
	State.ResumeAfter = os.clock() + RESPAWN_GRACE_SECONDS
	State.StandWaitUntil = State.ResumeAfter + RESPAWN_STAND_WAIT_SECONDS
	log("reset:", tostring(reason or "character changed"))
end

local function inRespawnGrace()
	return os.clock() < (State.ResumeAfter or 0)
end

local function inRespawnStandWait()
	return os.clock() >= (State.ResumeAfter or 0) and os.clock() < (State.StandWaitUntil or 0)
end

local function inRespawnHold()
	return inRespawnGrace() or inRespawnStandWait()
end

local function getBackpack(timeout)
	local backpack = LocalPlayer:FindFirstChildOfClass("Backpack") or LocalPlayer:FindFirstChild("Backpack")
	local deadline = os.clock() + math.max(tonumber(timeout) or 0, 0)

	while not backpack and State.Running and os.clock() < deadline do
		task.wait(0.1)
		backpack = LocalPlayer:FindFirstChildOfClass("Backpack") or LocalPlayer:FindFirstChild("Backpack")
	end

	return backpack
end

local function getCharacter(timeout)
	local character = LocalPlayer.Character
	local deadline = os.clock() + math.max(tonumber(timeout) or 0, 0)

	while not character and State.Running and os.clock() < deadline do
		task.wait(0.1)
		character = LocalPlayer.Character
	end

	return character
end

local function getHumanoid(character, timeout)
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local deadline = os.clock() + math.max(tonumber(timeout) or 0, 0)

	while not humanoid and State.Running and os.clock() < deadline do
		task.wait(0.1)
		character = character or LocalPlayer.Character
		humanoid = character and character:FindFirstChildOfClass("Humanoid")
	end

	return humanoid
end

local function getRootPart(character, timeout)
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local deadline = os.clock() + math.max(tonumber(timeout) or 0, 0)

	while not root and State.Running and os.clock() < deadline do
		task.wait(0.1)
		character = character or LocalPlayer.Character
		root = character and character:FindFirstChild("HumanoidRootPart")
	end

	return root
end

local function getToolCount(tool)
	for _, attrName in ipairs({ "Count", "Amount", "Quantity" }) do
		local count = tonumber(tool:GetAttribute(attrName))
		if count ~= nil then
			return count
		end
	end

	return nil
end

local function toolHasStock(tool)
	local count = getToolCount(tool)
	return count == nil or count > 0
end

local function toolMatches(tool, attributeName, itemName)
	if not (tool and tool:IsA("Tool")) then
		return false
	end

	if tool:GetAttribute(attributeName) == itemName then
		return true
	end

	if normalizedContains(tool.Name, itemName) then
		return true
	end

	local attrValue = tool:GetAttribute(attributeName)
	return attrValue ~= nil and normalizedContains(attrValue, itemName)
end

local function findTool(attributeName, itemName, timeout)
	local deadline = os.clock() + math.max(tonumber(timeout) or 0, 0)

	local function scan()
		local containers = {
			LocalPlayer.Character,
			getBackpack(0),
		}

		for _, container in ipairs(containers) do
			if container then
				for _, descendant in ipairs(container:GetDescendants()) do
					if toolMatches(descendant, attributeName, itemName) and toolHasStock(descendant) then
						return descendant
					end
				end
			end
		end
	end

	local tool = scan()
	if tool then
		return tool
	end

	while State.Running and os.clock() < deadline do
		task.wait(0.15)

		tool = scan()
		if tool then
			return tool
		end
	end

	return nil
end

local function requireToolOrRejoin(attributeName, itemName)
	if inRespawnHold() then
		return nil
	end

	local tool = findTool(attributeName, itemName, TOOL_WAIT_TIMEOUT)
	if not tool then
		rejoin(itemName .. " depleted")
		return nil
	end

	return tool
end

local function equipTool(tool)
	if not tool then
		return false
	end

	local character = getCharacter(CHARACTER_WAIT_TIMEOUT)
	if not character then
		return false
	end

	if tool.Parent == character then
		return true
	end

	local humanoid = getHumanoid(character, CHARACTER_WAIT_TIMEOUT)
	if not humanoid then
		return false
	end

	local backpack = getBackpack(0)
	if backpack and tool.Parent ~= backpack and tool.Parent ~= character then
		pcall(function()
			tool.Parent = backpack
		end)
		task.wait(0.05)
	end

	pcall(function()
		humanoid:UnequipTools()
	end)

	for _ = 1, 5 do
		pcall(function()
			humanoid:EquipTool(tool)
		end)

		if tool.Parent ~= character then
			pcall(function()
				tool.Parent = character
			end)
		end

		local startedAt = os.clock()
		while State.Running and os.clock() - startedAt < 0.6 do
			if tool.Parent == character then
				task.wait(0.05)
				return true
			end
			task.wait(0.05)
		end
	end

	return tool.Parent == character
end

local function ownerMatches(plot, ownerName)
	if not plot then
		return false
	end

	local owner = plot:GetAttribute("Owner")
	if normalizedContains(owner, ownerName) then
		return true
	end

	local targetPlayer = Players:FindFirstChild(ownerName)
	local ownerUserId = tonumber(plot:GetAttribute("OwnerUserId"))
	return targetPlayer and ownerUserId == targetPlayer.UserId
end

local function findTargetPlot()
	local ownerNames = getActiveOwnerNames()

	for _, plot in ipairs(Gardens:GetChildren()) do
		if plot:IsA("Model") then
			for _, ownerName in ipairs(ownerNames) do
				if ownerMatches(plot, ownerName) then
					lockSelectedOwner(ownerName)
					return plot, ownerName
				end
			end
		end
	end

	for _, ownerName in ipairs(ownerNames) do
		local targetPlayer = Players:FindFirstChild(ownerName)
		local plotId = targetPlayer and targetPlayer:GetAttribute("PlotId")
		if plotId then
			local plot = Gardens:FindFirstChild("Plot" .. tostring(plotId))
			if plot then
				lockSelectedOwner(ownerName)
				return plot, ownerName
			end
		end
	end

	return nil
end

local function getPlotId(plot)
	return plot and tonumber(tostring(plot.Name):match("%d+"))
end

local function getPlantName(plant)
	return plant:GetAttribute("SeedName")
		or plant:GetAttribute("PlantName")
		or plant:GetAttribute("FruitName")
		or plant:GetAttribute("CorePartName")
		or plant:GetAttribute("Name")
		or plant.Name
end

local function modelPosition(model)
	if not model then
		return nil
	end

	local ok, pivot = pcall(function()
		return model:GetPivot()
	end)
	if ok and pivot then
		return pivot.Position
	end

	local primary = model:IsA("Model") and model.PrimaryPart
	if primary then
		return primary.Position
	end

	local part = model:IsA("BasePart") and model or model:FindFirstChildWhichIsA("BasePart", true)
	return part and part.Position or nil
end

local function findDragonBreathPlant(plot)
	local plantsFolder = plot and plot:FindFirstChild("Plants")
	if not plantsFolder then
		return nil
	end

	local bestPlant
	local bestDepth = math.huge

	for _, descendant in ipairs(plantsFolder:GetDescendants()) do
		if descendant:IsA("Model") or descendant:IsA("Folder") or descendant:IsA("BasePart") then
			if normalizedContains(getPlantName(descendant), TARGET_PLANT_NAME) then
				local depth = 0
				local parent = descendant.Parent
				while parent and parent ~= plantsFolder do
					depth += 1
					parent = parent.Parent
				end

				if depth < bestDepth and modelPosition(descendant) then
					bestDepth = depth
					bestPlant = descendant
				end
			end
		end
	end

	return bestPlant
end

local function getPlantAreaParts(plot)
	local parts = {}

	for _, part in ipairs(CollectionService:GetTagged("PlantArea")) do
		if part:IsA("BasePart") and part:IsDescendantOf(plot) then
			table.insert(parts, part)
		end
	end

	if #parts > 0 then
		return parts
	end

	for _, descendant in ipairs(plot:GetDescendants()) do
		if descendant:IsA("BasePart") and CollectionService:HasTag(descendant, "PlantArea") then
			table.insert(parts, descendant)
		end
	end

	return parts
end

local function closestPointOnPart(part, worldPosition)
	local localPosition = part.CFrame:PointToObjectSpace(worldPosition)
	local halfSize = part.Size * 0.5
	local clamped = Vector3.new(
		math.clamp(localPosition.X, -halfSize.X, halfSize.X),
		halfSize.Y,
		math.clamp(localPosition.Z, -halfSize.Z, halfSize.Z)
	)

	return part.CFrame:PointToWorldSpace(clamped)
end

local function projectToPlantArea(plot, position)
	local parts = getPlantAreaParts(plot)
	if #parts == 0 then
		return nil
	end

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = parts

	local origin = Vector3.new(position.X, position.Y + 150, position.Z)
	local result = workspace:Raycast(origin, Vector3.new(0, -320, 0), params)
	if result and result.Instance and result.Instance:IsDescendantOf(plot) then
		return result.Position
	end

	local bestPosition
	local bestDistance = math.huge
	for _, part in ipairs(parts) do
		local candidate = closestPointOnPart(part, position)
		local distance = (Vector3.new(candidate.X, 0, candidate.Z) - Vector3.new(position.X, 0, position.Z)).Magnitude
		if distance < bestDistance then
			bestDistance = distance
			bestPosition = candidate
		end
	end

	return bestPosition
end

local function resolveTarget(plot)
	if State.TargetPlot == plot and State.TargetPlant and State.TargetPlant.Parent and State.TargetPosition then
		return true
	end

	local plant = findDragonBreathPlant(plot)
	if not plant then
		return false, TARGET_PLANT_NAME .. " not found in " .. getOwnerLabel() .. "'s plot"
	end

	local plantPosition = modelPosition(plant)
	if not plantPosition then
		return false, "Dragon's Breath position not found"
	end

	local placePosition = projectToPlantArea(plot, plantPosition)
	if not placePosition then
		return false, "PlantArea not found near Dragon's Breath"
	end

	local direction = Vector3.new(1, 0, 0)
	local character = getCharacter(0)
	local root = getRootPart(character, 0)
	if root then
		local delta = Vector3.new(root.Position.X - plantPosition.X, 0, root.Position.Z - plantPosition.Z)
		if delta.Magnitude > 0.05 then
			direction = delta.Unit
		end
	end

	local nearPosition = projectToPlantArea(plot, plantPosition + (direction * PLACE_OFFSET_DISTANCE)) or placePosition
	local tweenPosition = projectToPlantArea(plot, nearPosition + (direction * TWEEN_OFFSET_DISTANCE)) or nearPosition

	State.TargetPlot = plot
	State.TargetPlant = plant
	State.TargetPosition = nearPosition
	State.TweenPosition = tweenPosition

	log(
		("target ready | plot=%s | plant=%s | place=%.2f, %.2f, %.2f"):format(
			plot.Name,
			plant:GetFullName(),
			nearPosition.X,
			nearPosition.Y,
			nearPosition.Z
		)
	)

	return true
end

local function getTweenTargetPosition()
	return State.TweenPosition or State.TargetPosition
end

local function horizontalDistance(a, b)
	if not (a and b) then
		return math.huge
	end

	return (Vector3.new(a.X, 0, a.Z) - Vector3.new(b.X, 0, b.Z)).Magnitude
end

local function isNearTarget(root)
	local target = getTweenTargetPosition()
	return root and target and horizontalDistance(root.Position, target) <= TWEEN_REACHED_DISTANCE
end

local function tweenToTarget()
	local character = getCharacter(CHARACTER_WAIT_TIMEOUT)
	local humanoid = getHumanoid(character, CHARACTER_WAIT_TIMEOUT)
	local root = getRootPart(character, CHARACTER_WAIT_TIMEOUT)
	local target = getTweenTargetPosition()

	if not (humanoid and root and target) then
		return false, "character not ready"
	end

	if humanoid.Health <= 0 then
		resetLogic("health zero")
		return false, "character dead"
	end

	local token = State.ResetToken
	if isNearTarget(root) then
		return true
	end

	local distance = horizontalDistance(root.Position, target)
	local speed = math.max(tonumber(humanoid.WalkSpeed) or 16, 1)
	local duration = math.clamp(distance / speed, 0.05, TWEEN_MAX_SECONDS_PER_MOVE)
	local timeout = duration + 0.5
	local startedAt = os.clock()
	local heightOffset = math.max(3, tonumber(humanoid.HipHeight) or 0)
	if root then
		heightOffset = math.max(heightOffset, (root.Size.Y * 0.5) + 1)
	end
	local rootTarget = Vector3.new(target.X, target.Y + heightOffset, target.Z)
	local lookVector = root.CFrame.LookVector
	local flatLookVector = Vector3.new(lookVector.X, 0, lookVector.Z)
	if flatLookVector.Magnitude < 0.05 then
		flatLookVector = Vector3.new(0, 0, -1)
	end
	local tween = TweenService:Create(
		root,
		TweenInfo.new(duration, Enum.EasingStyle.Linear, Enum.EasingDirection.InOut),
		{ CFrame = CFrame.new(rootTarget, rootTarget + flatLookVector.Unit) }
	)

	pcall(function()
		humanoid.AutoRotate = true
	end)

	tween:Play()

	while State.Running and token == State.ResetToken and os.clock() - startedAt <= timeout do
		if humanoid.Health <= 0 then
			tween:Cancel()
			resetLogic("health zero")
			return false, "character dead"
		end

		if isNearTarget(root) then
			tween:Cancel()
			return true
		end

		task.wait(0.05)
	end

	tween:Cancel()
	return isNearTarget(root), "tween timeout"
end

local function sprinklersFolder(plot)
	return plot and plot:FindFirstChild("Sprinklers")
end

local function hasSprinklerInPlot(plot)
	local folder = sprinklersFolder(plot)
	if not folder then
		return false
	end

	for _, child in ipairs(folder:GetChildren()) do
		if child:IsA("Model") or child:IsA("BasePart") or child:IsA("Folder") then
			return true
		end
	end

	return false
end

local function waitForSprinkler(plot, timeout)
	local deadline = os.clock() + math.max(tonumber(timeout) or 0, 0)
	while State.Running and os.clock() < deadline do
		if hasSprinklerInPlot(plot) then
			return true
		end
		task.wait(0.2)
	end

	return hasSprinklerInPlot(plot)
end

local function placeSprinkler(plot)
	local tool = requireToolOrRejoin("Sprinkler", SPRINKLER_NAME)
	if not tool then
		return false, "missing " .. SPRINKLER_NAME
	end

	local plotId = getPlotId(plot)
	if not plotId then
		return false, "plot id not found"
	end

	equipTool(tool)

	local ok, err = pcall(function()
		Networking.Place.PlaceSprinkler:Fire(State.TargetPosition, SPRINKLER_NAME, tool, plotId)
	end)
	if not ok then
		return false, tostring(err)
	end

	log(("placed %s near %s"):format(SPRINKLER_NAME, TARGET_PLANT_NAME))
	waitForSprinkler(plot, 3)
	return true
end

local function ensureSprinkler(plot)
	if hasSprinklerInPlot(plot) then
		return true
	end

	local tweened, tweenMessage = tweenToTarget()
	if not tweened then
		return false, tweenMessage
	end

	return placeSprinkler(plot)
end

local function useWateringCan()
	local tool = requireToolOrRejoin("WateringCan", WATERING_CAN_NAME)
	if not tool then
		return false, "missing " .. WATERING_CAN_NAME
	end

	local position = State.TargetPosition
	if not position then
		return false, "target position not ready"
	end

	equipTool(tool)

	local ok, err = pcall(function()
		Networking.WateringCan.UseWateringCan:Fire(position - Vector3.new(0, 0.3, 0), WATERING_CAN_NAME, tool)
	end)
	if not ok then
		return false, tostring(err)
	end

	log(("watered %s with %s"):format(TARGET_PLANT_NAME, WATERING_CAN_NAME))
	return true
end

local function waitWithSprinklerMaintenance(plot, seconds)
	local deadline = os.clock() + seconds
	while State.Running and os.clock() < deadline do
		if inRespawnHold() then
			task.wait(0.5)
			continue
		end

		if not findTool("Sprinkler", SPRINKLER_NAME, 0) then
			rejoin(SPRINKLER_NAME .. " depleted")
			return
		end

		if not findTool("WateringCan", WATERING_CAN_NAME, 0) then
			rejoin(WATERING_CAN_NAME .. " depleted")
			return
		end

		if not hasSprinklerInPlot(plot) then
			local ready, message = ensureSprinkler(plot)
			if not ready then
				setStatus(message or "sprinkler not ready")
			end
		end

		local character = getCharacter(0)
		local humanoid = getHumanoid(character, 0)
		local root = getRootPart(character, 0)
		if humanoid and root and humanoid.Health > 0 and not isNearTarget(root) then
			local tweened, message = tweenToTarget()
			if not tweened then
				setStatus(message or "tween failed")
			end
		elseif humanoid and humanoid.Health <= 0 then
			resetLogic("health zero")
		end

		task.wait(math.min(SPRINKLER_CHECK_INTERVAL, math.max(0.1, deadline - os.clock())))
	end
end

local function wireCharacter(character)
	task.defer(function()
		local humanoid = getHumanoid(character, CHARACTER_WAIT_TIMEOUT)
		if humanoid then
			connect(humanoid.Died, function()
				resetLogic("died")
			end)
		end
	end)
end

connect(LocalPlayer.CharacterAdded, function(character)
	resetLogic("respawn")
	wireCharacter(character)
end)

if LocalPlayer.Character then
	wireCharacter(LocalPlayer.Character)
end

task.spawn(function()
	log("loaded")

	while State.Running do
		if State.Rejoining then
			task.wait(1)
			continue
		end

		if inRespawnGrace() then
			setStatus(("waiting %.1fs after respawn"):format(math.max(0, State.ResumeAfter - os.clock())))
			task.wait(math.min(0.5, math.max(0.1, State.ResumeAfter - os.clock())))
			continue
		end

		if inRespawnStandWait() then
			setStatus(("standing %.0fs before loop"):format(math.max(0, State.StandWaitUntil - os.clock())))
			task.wait(1)
			continue
		end

		local sprinklerTool = findTool("Sprinkler", SPRINKLER_NAME, TOOL_WAIT_TIMEOUT)
		if not sprinklerTool then
			rejoin(SPRINKLER_NAME .. " depleted")
			continue
		end

		local wateringTool = findTool("WateringCan", WATERING_CAN_NAME, TOOL_WAIT_TIMEOUT)
		if not wateringTool then
			rejoin(WATERING_CAN_NAME .. " depleted")
			continue
		end

		local plot = findTargetPlot()
		if not plot then
			setStatus("waiting for plot owner " .. getOwnerLabel())
			task.wait(3)
			continue
		end

		local resolved, resolveMessage = resolveTarget(plot)
		if not resolved then
			setStatus(resolveMessage or "target not ready")
			task.wait(3)
			continue
		end

		local tweened, tweenMessage = tweenToTarget()
		if not tweened then
			setStatus(tweenMessage or "tween failed")
			task.wait(2)
			continue
		end

		local sprinklerReady, sprinklerMessage = ensureSprinkler(plot)
		if not sprinklerReady then
			setStatus(sprinklerMessage or "sprinkler not ready")
			task.wait(2)
			continue
		end

		local watered, waterMessage = useWateringCan()
		if not watered then
			setStatus(waterMessage or "watering failed")
			task.wait(2)
			continue
		end

		setStatus(("waiting %ds before next water"):format(WATER_INTERVAL))
		waitWithSprinklerMaintenance(plot, WATER_INTERVAL)
	end

	log("stopped")
end)
