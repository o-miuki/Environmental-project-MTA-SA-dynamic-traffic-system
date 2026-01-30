--[[
    TrafficGroundFix.lua (CLIENT)
    Uses getGroundPosition to fix NPC Z position and prevent falling through ground.
    This runs on client because getGroundPosition is client-side only.
]]

local GROUND_CHECK_INTERVAL = 1000 -- ms
local GROUND_FIX_OFFSET = 0.5      -- meters above ground

-- Fix Z position of traffic elements
local function fixElementGroundPosition(element)
    if not isElement(element) then return end
    if not getElementData(element, "traffic:managed") then return end
    
    local ex, ey, ez = getElementPosition(element)
    local groundZ = getGroundPosition(ex, ey, ez + 5) -- Ray from slightly above
    
    if groundZ then
        local elementType = getElementType(element)
        local offset = GROUND_FIX_OFFSET
        
        if elementType == "vehicle" then
            offset = 1.0 -- Vehicles need more height
        elseif elementType == "ped" then
            offset = 0.3
        end
        
        -- Only fix if element is below or too close to ground
        if ez < groundZ + offset - 0.5 then
            setElementPosition(element, ex, ey, groundZ + offset)
        end
    end
end

-- Periodic check for all traffic elements
local function groundCheckLoop()
    -- Check all managed vehicles
    for _, veh in ipairs(getElementsByType("vehicle", root, true)) do
        if getElementData(veh, "traffic:managed") then
            fixElementGroundPosition(veh)
        end
    end
    
    -- Check all managed peds (not in vehicles)
    for _, ped in ipairs(getElementsByType("ped", root, true)) do
        if getElementData(ped, "traffic:managed") and not isPedInVehicle(ped) then
            fixElementGroundPosition(ped)
        end
    end
end

-- Fix element when it streams in
addEventHandler("onClientElementStreamIn", root, function()
    if getElementData(source, "traffic:managed") then
        -- Delay to let physics stabilize
        setTimer(function()
            fixElementGroundPosition(source)
        end, 500, 1)
    end
end)

-- Start periodic ground check
setTimer(groundCheckLoop, GROUND_CHECK_INTERVAL, 0)

outputDebugString("[TrafficGroundFix] Client-side ground detection initialized.")
