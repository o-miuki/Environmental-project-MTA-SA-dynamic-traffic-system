--[[
    TrafficScanner.lua
    Client-side logic to find where to spawn traffic.
    Scans nodes in player view and requests spawn from server.
]]

TrafficScanner = {}
TrafficScanner.__index = TrafficScanner

function TrafficScanner:init()
    -- DESATIVADO: Agora usamos spawn server-side
    -- O servidor roda serverSpawnTick() a cada 100ms
    self.enabled = false
    outputDebugString("[TrafficScanner] DISABLED - Using server-side spawn now.")
    
    -- Ainda precisamos carregar o mapa para outras funcionalidades client
    self.map = TrafficMap:getInstance()
    self.map:init()
end

function TrafficScanner:scan()
    if not self.enabled then return end
    
    local x, y, z = getElementPosition(localPlayer)
    -- local cx, cy, cz, ctx, cty, ctz = getCameraMatrix()
    
    -- 1. Get nodes around
    -- Optimization: Map should have spatial hash. Using brute force for now (needs fix for prod)
    local nearbyNodes = self.map:getNodesInRange(x, y, self.spawnRadius)
    
    -- DEBUG
    if #nearbyNodes > 0 then
        outputDebugString("TrafficScanner: Found " .. #nearbyNodes .. " nodes nearby.")
    end
    
    -- Obter densidade do servidor (sync via elementData ou export)
    local density = tonumber(getElementData(localPlayer, "traffic:density")) or 0.15
    
    -- Calcular quantos requests por tick baseado na densidade
    -- Densidade 0.10 = 5 requests, 0.22 = 10 requests, 0.50 = 20 requests
    local maxRequests = math.floor(density * 40) + 2
    maxRequests = math.min(maxRequests, 20) -- Cap em 20
    
    local requestsThisTick = 0
    for _, node in ipairs(nearbyNodes) do
        if requestsThisTick >= maxRequests then break end
        
        if self:isValidSpawnCandidate(node, x, y, z) then
            -- 90% carros, 10% pedestres
            local roll = math.random()
            local spawnType = (roll < 0.10) and "ped" or "car"
            
            triggerServerEvent("traffic:requestSpawn", localPlayer, node.id, spawnType)
            requestsThisTick = requestsThisTick + 1
        end
    end
end

function TrafficScanner:isValidSpawnCandidate(node, px, py, pz)
    local dist = getDistanceBetweenPoints3D(node.x, node.y, node.z, px, py, pz)
    
    -- Too close?
    if dist < self.minSpawnDist then return false end
    
    -- On screen? (We WANT spawns just outside or far away, but for simplicity let's stick to range)
    if isLineOfSightClear(px, py, pz, node.x, node.y, node.z, true, false, false) then
        -- Visible... maybe we want to spawn behind camera?
        -- Modern games spawn mainly OUT of view, or far in view.
        -- Let's stick to simple distance logic for now.
        return true
    end
    
    return true
end

addEventHandler("onClientResourceStart", resourceRoot, function()
    TrafficScanner:init()
end)
