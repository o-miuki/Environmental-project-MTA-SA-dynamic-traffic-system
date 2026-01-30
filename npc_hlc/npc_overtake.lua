-- =============================================================================
-- NPC OVERTAKING SYSTEM v1.0
-- Allows NPCs to change lanes and overtake slower vehicles
-- =============================================================================

local DEBUG_OVERTAKE = false

-- =============================================================================
-- CONFIGURATION
-- =============================================================================
local OVERTAKE_CONFIG = {
    -- Timing
    DETECT_TIME_MS = 2000,        -- Wait 2s behind slower vehicle before overtake
    SIGNAL_TIME_MS = 800,         -- Signal for 0.8s before lane change
    LANE_CHANGE_TIME_MS = 1500,   -- Time to complete lane change
    MIN_PASS_TIME_MS = 2000,      -- Minimum time in passing lane
    
    -- Distances
    SAFETY_FRONT = 25,            -- Clear distance needed ahead in target lane
    SAFETY_REAR = 15,             -- Clear distance needed behind in target lane
    MIN_PASS_DISTANCE = 12,       -- Must pass target by this much before returning
    
    -- Speed thresholds
    SPEED_DIFF_THRESHOLD = 0.03,  -- Minimum speed difference to consider overtaking (5.4 km/h)
    OVERTAKE_SPEED_BOOST = 1.15,  -- Speed multiplier during overtaking
    
    -- Road requirements
    MIN_ROAD_SPEED = 60,          -- Only overtake on roads >= 60 km/h
    
    -- Lane offset (lateral distance in meters)
    LANE_WIDTH = 3.5,             -- Standard lane width
}

-- =============================================================================
-- STATE TRACKING
-- =============================================================================
local npc_overtake = {}  -- State per NPC

-- States: nil, "detecting", "signaling", "changing", "passing", "returning", "completing"

-- =============================================================================
-- HELPER FUNCTIONS
-- =============================================================================

-- Get current connection info for NPC
local function getCurrentConnection(npc)
    local connid = getElementData(npc, "npc.current_connection")
    if connid then
        return connid, conn_lanes and conn_lanes.right and conn_lanes.right[connid] or 0
    end
    return nil, 0
end

-- Check if road has multiple lanes (can overtake)
local function hasMultipleLanes(npc)
    local connid, rightLanes = getCurrentConnection(npc)
    if not connid then return false end
    
    local leftLanes = conn_lanes and conn_lanes.left and conn_lanes.left[connid] or 0
    return (leftLanes + rightLanes) >= 2
end

-- Check if NPC is on a suitable road for overtaking
local function isOvertakingRoad(npc)
    local baseSpeed = getElementData(npc, "npc_hlc:base_speed") or 0.5
    local roadSpeedKmh = baseSpeed * 180  -- Convert to km/h
    return roadSpeedKmh >= OVERTAKE_CONFIG.MIN_ROAD_SPEED
end

-- Get vehicle ahead that's blocking
local function getBlockingVehicle(npc)
    local threat = getElementData(npc, "sensor.frontal")
    if not threat or not threat.element then return nil end
    
    local other = threat.element
    if not isElement(other) or getElementType(other) ~= "vehicle" then return nil end
    
    -- Check if it's close enough to be blocking
    if threat.dist and threat.dist < 20 then
        return other, threat.dist
    end
    
    return nil
end

-- Check if target lane is clear (simple raycast-style check)
local function isTargetLaneClear(npc, leftOffset)
    local vehicle = getPedOccupiedVehicle(npc)
    if not vehicle then return false end
    
    local x, y, z = getElementPosition(vehicle)
    local _, _, rz = getElementRotation(vehicle)
    
    -- Calculate left lane position
    local rad = math.rad(rz + 90)  -- Perpendicular to heading
    local checkX = x + math.sin(rad) * leftOffset
    local checkY = y + math.cos(rad) * leftOffset
    
    -- Check for vehicles in the target area
    local nearbyVehicles = getElementsByType("vehicle")
    for _, veh in ipairs(nearbyVehicles) do
        if veh ~= vehicle and isElement(veh) then
            local vx, vy, vz = getElementPosition(veh)
            local dist = getDistanceBetweenPoints2D(checkX, checkY, vx, vy)
            
            -- Check if vehicle is in our target lane and within safety distance
            if dist < OVERTAKE_CONFIG.SAFETY_FRONT then
                -- Check if it's actually in the left lane area
                local lateralDist = math.abs((vx - x) * math.cos(rad) + (vy - y) * math.sin(rad))
                if lateralDist > (leftOffset - 2) and lateralDist < (leftOffset + 2) then
                    return false
                end
            end
        end
    end
    
    return true
end

-- Get current speed of blocking vehicle
local function getBlockingVehicleSpeed(blockingVeh)
    if not blockingVeh then return nil end
    local driver = getVehicleController(blockingVeh)
    if not driver then return nil end
    return getElementData(driver, "npc_hlc:drive_speed")
end

-- =============================================================================
-- MAIN OVERTAKE LOGIC
-- =============================================================================

function canStartOvertake(npc)
    -- Check basic conditions
    if not hasMultipleLanes(npc) then return false, "no_lanes" end
    if not isOvertakingRoad(npc) then return false, "slow_road" end
    
    -- Check if already overtaking
    if npc_overtake[npc] then return false, "already_overtaking" end
    
    -- Check if there's a blocking vehicle
    local blockingVeh, dist = getBlockingVehicle(npc)
    if not blockingVeh then return false, "no_blocker" end
    
    -- Compare speeds
    local mySpeed = getElementData(npc, "npc_hlc:drive_speed") or 0.5
    local theirSpeed = getBlockingVehicleSpeed(blockingVeh) or mySpeed
    
    local speedDiff = mySpeed - theirSpeed
    if speedDiff < OVERTAKE_CONFIG.SPEED_DIFF_THRESHOLD then 
        return false, "not_faster" 
    end
    
    -- Check if target lane is clear
    if not isTargetLaneClear(npc, OVERTAKE_CONFIG.LANE_WIDTH) then
        return false, "lane_blocked"
    end
    
    -- Check not in curve (check current task)
    local taskType = getElementData(npc, "npc_hlc:current_task_type")
    if taskType == "driveAroundBend" then
        return false, "in_curve"
    end
    
    return true, blockingVeh
end

function startOvertake(npc, blockingVeh)
    local now = getTickCount()
    
    npc_overtake[npc] = {
        state = "detecting",
        startTime = now,
        stateStartTime = now,
        blockingVeh = blockingVeh,
        originalLane = getElementData(npc, "npc.laneOffset") or 0,
        targetLane = OVERTAKE_CONFIG.LANE_WIDTH,
    }
    
    if DEBUG_OVERTAKE then
        outputDebugString("[Overtake] NPC starting overtake detection")
    end
end

function updateOvertake(npc)
    local state = npc_overtake[npc]
    if not state then return end
    
    local vehicle = getPedOccupiedVehicle(npc)
    if not vehicle then
        cancelOvertake(npc)
        return
    end
    
    local now = getTickCount()
    local stateTime = now - state.stateStartTime
    
    -- State machine
    if state.state == "detecting" then
        -- Wait before committing to overtake
        if stateTime >= OVERTAKE_CONFIG.DETECT_TIME_MS then
            -- Verify conditions still valid
            local canDo, reason = canStartOvertake(npc)
            if canDo or reason == "already_overtaking" then
                state.state = "signaling"
                state.stateStartTime = now
                -- Activate left turn signal
                setElementData(vehicle, "turn_left", true)
                setElementData(vehicle, "turn_right", false)
                if DEBUG_OVERTAKE then
                    outputDebugString("[Overtake] NPC signaling left")
                end
            else
                cancelOvertake(npc)
            end
        end
        
    elseif state.state == "signaling" then
        -- Signal before lane change
        if stateTime >= OVERTAKE_CONFIG.SIGNAL_TIME_MS then
            -- Final check before lane change
            if isTargetLaneClear(npc, OVERTAKE_CONFIG.LANE_WIDTH) then
                state.state = "changing"
                state.stateStartTime = now
                if DEBUG_OVERTAKE then
                    outputDebugString("[Overtake] NPC changing to left lane")
                end
            else
                cancelOvertake(npc)
            end
        end
        
    elseif state.state == "changing" then
        -- Smoothly move to left lane
        local progress = math.min(1.0, stateTime / OVERTAKE_CONFIG.LANE_CHANGE_TIME_MS)
        local currentOffset = state.originalLane + (state.targetLane - state.originalLane) * progress
        setElementData(npc, "npc.laneOffset", currentOffset)
        
        if progress >= 1.0 then
            state.state = "passing"
            state.stateStartTime = now
            state.passStartPos = {getElementPosition(vehicle)}
            -- Turn off signal
            setElementData(vehicle, "turn_left", false)
            if DEBUG_OVERTAKE then
                outputDebugString("[Overtake] NPC now passing")
            end
        end
        
    elseif state.state == "passing" then
        -- Check if we've passed the blocking vehicle
        local passed = false
        
        if state.blockingVeh and isElement(state.blockingVeh) then
            local myX, myY = getElementPosition(vehicle)
            local theirX, theirY = getElementPosition(state.blockingVeh)
            
            -- Check if we're ahead of them
            local _, _, myRot = getElementRotation(vehicle)
            local rad = math.rad(myRot)
            local forwardX, forwardY = math.sin(rad), math.cos(rad)
            
            -- Project relative position onto forward direction
            local relX, relY = myX - theirX, myY - theirY
            local forwardDist = relX * forwardX + relY * forwardY
            
            if forwardDist > OVERTAKE_CONFIG.MIN_PASS_DISTANCE then
                passed = true
            end
        else
            -- Blocking vehicle gone, consider passed
            passed = stateTime >= OVERTAKE_CONFIG.MIN_PASS_TIME_MS
        end
        
        if passed then
            state.state = "returning"
            state.stateStartTime = now
            -- Signal right
            setElementData(vehicle, "turn_right", true)
            if DEBUG_OVERTAKE then
                outputDebugString("[Overtake] NPC returning to right lane")
            end
        end
        
    elseif state.state == "returning" then
        -- Move back to original lane
        local progress = math.min(1.0, stateTime / OVERTAKE_CONFIG.LANE_CHANGE_TIME_MS)
        local currentOffset = state.targetLane + (state.originalLane - state.targetLane) * progress
        setElementData(npc, "npc.laneOffset", currentOffset)
        
        if progress >= 1.0 then
            state.state = "completing"
            state.stateStartTime = now
        end
        
    elseif state.state == "completing" then
        -- Clear everything
        setElementData(vehicle, "turn_left", false)
        setElementData(vehicle, "turn_right", false)
        setElementData(npc, "npc.laneOffset", 0)
        npc_overtake[npc] = nil
        if DEBUG_OVERTAKE then
            outputDebugString("[Overtake] NPC overtake complete")
        end
    end
end

function cancelOvertake(npc)
    local state = npc_overtake[npc]
    if not state then return end
    
    local vehicle = getPedOccupiedVehicle(npc)
    if vehicle then
        setElementData(vehicle, "turn_left", false)
        setElementData(vehicle, "turn_right", false)
    end
    
    -- Smoothly return to original lane if we were mid-change
    if state.state == "changing" or state.state == "passing" then
        setElementData(npc, "npc.laneOffset", 0)
    end
    
    npc_overtake[npc] = nil
    
    if DEBUG_OVERTAKE then
        outputDebugString("[Overtake] NPC overtake cancelled")
    end
end

-- =============================================================================
-- SPEED BOOST DURING OVERTAKE
-- =============================================================================

function getOvertakeSpeedMultiplier(npc)
    local state = npc_overtake[npc]
    if not state then return 1.0 end
    
    -- Boost speed during passing phase
    if state.state == "passing" or state.state == "changing" then
        return OVERTAKE_CONFIG.OVERTAKE_SPEED_BOOST
    end
    
    return 1.0
end

-- =============================================================================
-- CHECK FOR NEW OVERTAKES (called from main speed timer)
-- =============================================================================

function checkAndUpdateOvertake(npc)
    -- Update existing overtake
    if npc_overtake[npc] then
        updateOvertake(npc)
        return
    end
    
    -- Check if we should start a new overtake (with some randomness to prevent all NPCs overtaking at once)
    if math.random() > 0.05 then return end  -- Only check 5% of the time
    
    local canDo, blocker = canStartOvertake(npc)
    if canDo and blocker then
        startOvertake(npc, blocker)
    end
end

-- =============================================================================
-- CLEANUP
-- =============================================================================

function cleanupOvertakeState(npc)
    npc_overtake[npc] = nil
end

-- Cleanup on element destroy
addEventHandler("onElementDestroy", root, function()
    if getElementType(source) == "ped" then
        npc_overtake[source] = nil
    end
end)

outputChatBox("[NPC Overtake] v1.0 loaded", root, 0, 200, 255)
