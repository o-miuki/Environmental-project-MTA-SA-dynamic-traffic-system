--[[
    TrafficManager.lua
    Central Singleton for managing server-side traffic logic.
    Follows "Manager" pattern.
]]

TrafficManager = {}
TrafficManager.__index = TrafficManager

-- Singleton Instance
local instance = nil

function TrafficManager:getInstance()
    if not instance then
        instance = setmetatable({}, TrafficManager)
    end
    return instance
end

function TrafficManager:init()
    if self.initialized then return end
    
    -- Carregar offsets de altura (zoffsets.lua)
    if loadZOffsets then loadZOffsets() end
    
    self.activeVehicles = {}
    self.activePeds = {}
    self.totalNPCCount = 0
    
    -- Square grid system (100m squares)
    self.SQUARE_SIZE = 100
    self.squarePopulation = {}  -- [dim][y][x] = {count, list}
    
    -- Configuração GLOBAL (legacy-style)
    self.config = {
        maxTotalNPCs = 500,        -- Limite global
        spawnInterval = 100,       -- Loop a cada 100ms
        spawnRadius = 150,         -- Spawnar até 150m do player
        minSpawnDist = 40,         -- Não spawnar muito perto
        freezeDistance = 250,
        despawnDistance = 400,
        gcInterval = 5000
    }

    -- Inicializar Mapa de Tráfego (Shared)
    local map = TrafficMap:getInstance()
    map:init()
    if #map.nodes == 0 then
        outputDebugString("[TrafficManager] CRITICAL: Failed to load traffic nodes!")
        return
    end
    
    -- Pré-calcular conexões por quadrado (como legacy)
    self:buildSquareConnectionCache()

    self:registerEvents()
    self:startSpawnLoop()
    self:startGarbageCollector()
    
    -- Inicializar sistema de sensores (legacy)
    NPCSensorSystem:getInstance():init()
    
    outputDebugString("[TrafficManager] SERVER-SIDE spawn system initialized. Max " .. self.config.maxTotalNPCs .. " NPCs.")
    self.initialized = true
end

function TrafficManager:buildSquareConnectionCache()
    -- Cache de conexões por quadrado para spawn rápido
    self.squareConnections = {}
    local map = TrafficMap:getInstance()
    local nodeCount = 0
    
    -- Iterar nodes (pode ser array ou hash)
    if map.nodes then
        for nodeID, node in pairs(map.nodes) do
            if node and node.x and node.y then
                local sqX = math.floor(node.x / self.SQUARE_SIZE)
                local sqY = math.floor(node.y / self.SQUARE_SIZE)
                local key = sqX .. "," .. sqY
                
                if not self.squareConnections[key] then
                    self.squareConnections[key] = {nodes = {}, x = sqX, y = sqY}
                end
                table.insert(self.squareConnections[key].nodes, nodeID)
                nodeCount = nodeCount + 1
            end
        end
    end
    
    self._squareCount = 0
    for _ in pairs(self.squareConnections) do self._squareCount = self._squareCount + 1 end
    outputDebugString("[TrafficManager] Built square cache: " .. self._squareCount .. " squares, " .. nodeCount .. " nodes")
end

function TrafficManager:startSpawnLoop()
    -- Loop principal de spawn (como legacy generateTraffic)
    setTimer(function()
        self:serverSpawnTick()
    end, self.config.spawnInterval, 0)
end

function TrafficManager:registerEvents()
    -- Cleanup automático ao destruir
    addEventHandler("onElementDestroy", root, function()
        if self.activeVehicles[source] then self:onVehicleDestroyed(source) end
        if self.activePeds[source] then self:onPedDestroyed(source) end
    end)
end

-- =====================================================
-- SERVER SPAWN TICK (Legacy-style generateTraffic)
-- =====================================================
function TrafficManager:serverSpawnTick()
    -- Verificar limite global
    if self.totalNPCCount >= self.config.maxTotalNPCs then
        return
    end
    
    local players = getElementsByType("player")
    if #players == 0 then return end
    
    -- DEBUG: Log de status
    if not self._debugTick then self._debugTick = 0 end
    self._debugTick = self._debugTick + 1
    if self._debugTick % 50 == 0 then  -- Log a cada 5 segundos
        outputDebugString("[TrafficManager] Tick #" .. self._debugTick .. " | NPCs: " .. (self.totalNPCCount or 0) .. "/" .. self.config.maxTotalNPCs)
        outputDebugString("[TrafficManager] Fails: NoNode=" .. (self._failNoNode or 0) .. " Dist=" .. (self._failDist or 0) .. " NoNeighbor=" .. (self._failNoNeighbor or 0) .. " NoLane=" .. (self._failNoLane or 0))
        -- Reset counters
        self._failNoNode, self._failDist, self._failCollision, self._failNoNeighbor, self._failNoLane, self._failDist3D = 0, 0, 0, 0, 0, 0
        self._spawnAttempts = 0
    end
    
    local players = getElementsByType("player")
    if #players == 0 then return end
    
    -- DEBUG: Scan every tick until fixed
    -- outputDebugString("[TrafficManager] Scanning for " .. #players .. " players...")

    for _, player in ipairs(players) do
        local x, y, z = getElementPosition(player)
        local dim = getElementDimension(player)
        
        -- Get nearby nodes (scan radius 300)
        local nodes = self.map:getNearbyNodes(x, y, z, 300)
        
        if #nodes > 0 then
            -- Attempt spawn on random node (force 1 spawn per tick per player if below limit)
            local node = nodes[math.random(#nodes)]
            if node then
                 -- Force simpler logic for testing
                 -- outputDebugString("[TrafficManager] Attempting to spawn at node " .. tostring(node.id))
                 self:spawnAtNode(node.id, "car", dim, x, y, z)
            end
        else
            outputDebugString("[TrafficManager] No nodes found near player " .. getPlayerName(player))
            self._failNoNode = (self._failNoNode or 0) + 1
        end
    end
end

-- Spawn direto em um node (substitui handleSpawnRequest)
function TrafficManager:spawnAtNode(nodeID, spawnType, dim, playerX, playerY, playerZ)
    -- DEBUG counters
    self._spawnAttempts = (self._spawnAttempts or 0) + 1
    
    local map = TrafficMap:getInstance()
    local node = map.nodes[nodeID]
    if not node then 
        self._failNoNode = (self._failNoNode or 0) + 1
        return 
    end
    
    -- isSpawnSafe checks
    local spawnX, spawnY, spawnZ = node.x, node.y, node.z
    
    -- Distância ao player
    local dx, dy = spawnX - playerX, spawnY - playerY
    local distSq = dx*dx + dy*dy
    
    -- Muito perto (40m) ou muito longe (150m)
    if distSq < 1600 or distSq > 22500 then 
        self._failDist = (self._failDist or 0) + 1
        return 
    end
    
    -- FOV check - não spawnar na frente do player
    local dist2D = math.sqrt(distSq)
    -- (Simplificado - spawnar em qualquer direção por enquanto)
    
    -- Colisão com veículos existentes
    for vehicle, _ in pairs(self.activeVehicles) do
        if isElement(vehicle) then
            local vx, vy = getElementPosition(vehicle)
            if (vx - spawnX)^2 + (vy - spawnY)^2 < 100 then
                self._failCollision = (self._failCollision or 0) + 1
                return  -- 10m mínimo
            end
        end
    end
    
    -- Obter conexão para direção
    local targetNode, targetID, conn = map:getRandomNeighbor(nodeID, nil, (spawnType == "ped") and 1 or 2, false)
    if not targetNode then 
        self._failNoNeighbor = (self._failNoNeighbor or 0) + 1
        return 
    end
    
    -- Calcular posição e rotação (LEGACY EXACT)
    -- LEGACY: lane = (rl > 0) and 1 or 0 (usa faixa da direita se existir)
    local rl = (conn.lanes and conn.lanes.right) or 0
    local lane = (rl > 0) and 1 or 0
    
    local x1, y1, z1 = map:getLanePosition(nodeID, conn, lane, false)
    local x2, y2, z2 = map:getLanePosition(targetID, conn, lane, true)
    if not x1 or not x2 then 
        self._failNoLane = (self._failNoLane or 0) + 1
        return 
    end
    
    local dx, dy, dz = x2 - x1, y2 - y1, z2 - z1
    local dist2D = math.sqrt(dx*dx + dy*dy)
    local dist3D = math.sqrt(dx*dx + dy*dy + dz*dz)
    if dist3D < 0.1 then 
        self._failDist3D = (self._failDist3D or 0) + 1
        return 
    end
    
    -- Interpolar posição ao longo do segmento (30-70%)
    local connpos = 0.3 + math.random() * 0.4
    local x = x1*(1-connpos) + x2*connpos
    local y = y1*(1-connpos) + y2*connpos
    local z = z1*(1-connpos) + z2*connpos
    
    -- Rotação
    local rx = math.deg(math.atan2(dz, dist2D))
    local rz = -math.deg(math.atan2(dx, dy))
    
    -- =====================================================
    -- COLLISION CHECK NA POSIÇÃO DE SPAWN (não no node!)
    -- =====================================================
    local minDistSq = 225  -- 15 metros squared
    for vehicle, _ in pairs(self.activeVehicles) do
        if isElement(vehicle) then
            local vx, vy = getElementPosition(vehicle)
            if (vx - x)^2 + (vy - y)^2 < minDistSq then
                return  -- Muito perto de outro veículo
            end
        end
    end
    for ped, _ in pairs(self.activePeds) do
        if isElement(ped) then
            local px, py = getElementPosition(ped)
            if (px - x)^2 + (py - y)^2 < minDistSq then
                return  -- Muito perto de outro ped
            end
        end
    end
    
    -- Velocidade
    local maxSpeed = conn.maxspeed or 50
    local speedMPS = maxSpeed / 180
    local vmult = speedMPS / dist3D
    local vx, vy, vz = dx*vmult, dy*vmult, dz*vmult
    
    -- SPAWN!
    if spawnType == "ped" then
        local model = self:getRandomModel("ped")
        local finalZ = z + 1.0
        
        local ped = TrafficPed:new(model, x, y, finalZ, rz)
        if ped then
            setElementDimension(ped.element, dim)
            ped:enableHLC("walk")
            -- ped:startRoute(nodeID, targetID, conn)
            
            -- LEGACY ROUTE INITIALIZATION (ai.lua)
            if initPedRouteData and ped_lane then
                ped_lane[ped.element] = lane
                initPedRouteData(ped.element)
                addNodeToPedRoute(ped.element, nodeID)
                addNodeToPedRoute(ped.element, targetID, conn and conn.nb)
                for i = 1, 4 do addRandomNodeToPedRoute(ped.element) end
            end
            self:registerEntity(ped.element)
            self.totalNPCCount = self.totalNPCCount + 1
        end
    else
        -- SPAWNAR CARRO
        local model = self:getRandomModel("car")
        local modelZOff = (z_offset and z_offset[model]) or 1.0
        local finalZOffset = (modelZOff + 0.2) / math.cos(math.rad(rx))
        local finalZ = z + finalZOffset
        
        local vehicle = TrafficVehicle:new(model, x, y, finalZ, rx, 0, rz)
        if vehicle then
            setElementDimension(vehicle.element, dim)
            setElementVelocity(vehicle.element, vx, vy, vz)
            
            -- LEGACY: Chamar server_coldata para corrigir colisão de chão
            local server_coldata = getResourceFromName("server_coldata")
            if server_coldata and getResourceState(server_coldata) == "running" then
                call(server_coldata, "updateElementColData", vehicle.element)
            end
            
            -- Calcular velocidade legacy (GTA units ~ speed/180) para o HLC
            local legacySpeed = (conn.maxspeed or 50) / 180
            
            vehicle:spawnDriver(0, nodeID, targetID, conn, legacySpeed)
            
            -- LEGACY: Registrar sensores para o driver
            local driver = getVehicleOccupant(vehicle.element, 0)
            if driver then
                initNPCSensors(driver, vehicle.element, legacySpeed)
                
                -- LEGACY ROUTE INITIALIZATION (ai.lua)
                -- Isso corrige o teleport e garante rota correta
                if initPedRouteData and ped_lane then
                    ped_lane[driver] = lane
                    initPedRouteData(driver)
                    addNodeToPedRoute(driver, nodeID)
                    addNodeToPedRoute(driver, targetID, conn and conn.nb)
                    for i = 1, 4 do addRandomNodeToPedRoute(driver) end
                else
                    outputDebugString("[TrafficManager] ALERT: Legacy AI functions not found!")
                end
            end
            
            self:registerEntity(vehicle.element)
            self.totalNPCCount = self.totalNPCCount + 1
        end
    end
end

function TrafficManager:getPlayerNPCCount(player)
    return 0  -- Deprecated
end

function TrafficManager:handleSpawnRequest(player, nodeID, spawnType)
    -- Validar request
    if not isElement(player) then return end
    
    -- Anti-spam (100ms cooldown - reduzido para spawnar mais)
    local lastReq = self.lastRequestTimes and self.lastRequestTimes[player] or 0
    local now = getTickCount()
    if (now - lastReq) < 100 then 
        return 
    end
    self.lastRequestTimes = self.lastRequestTimes or {}
    self.lastRequestTimes[player] = now
    
    -- VERIFICAR LIMITE PER-PLAYER
    local playerCount = self:getPlayerNPCCount(player)
    if playerCount >= self.config.maxNPCsPerPlayer then 
        return 
    end
    
    -- Validar se node já está ocupado
    if self.occupiedNodes and self.occupiedNodes[nodeID] then 
        return 
    end
    
    -- Obter dados do node (precisamos do TrafficMap no server também!)
    local node = TrafficMap:getInstance().nodes[nodeID]
    if not node then 
        outputDebugString("Node not found in map: " .. nodeID)
        return 
    end
    
    -- ========================================
    -- isSpawnSafe (LEGACY generate.lua L361-401)
    -- ========================================
    local spawnX, spawnY, spawnZ = node.x, node.y, node.z
    
    -- 1. Verificar distância mínima aos players (40m = 1600 sq)
    for _, p in ipairs(getElementsByType("player")) do
        local px, py, pz = getElementPosition(p)
        local dx, dy, dz = spawnX - px, spawnY - py, spawnZ - pz
        local distSq = dx*dx + dy*dy + dz*dz
        
        -- Muito perto (< 40m) - não spawnar
        if distSq < 1600 then
            return
        end
        
        -- Campo de visão (< 80m) - verificar se está na frente do player
        if distSq < 6400 then
            local _, _, prz = getElementRotation(p)
            local prad = math.rad(prz)
            local pdx, pdy = -math.sin(prad), math.cos(prad)
            
            local dist2D = math.sqrt(dx*dx + dy*dy)
            if dist2D > 0 then
                local dot = (dx * pdx + dy * pdy) / dist2D
                if dot > 0.6 then  -- Ângulo frontal (~53 graus)
                    return  -- Não spawnar na frente do player
                end
            end
        end
    end
    
    -- 2. Verificar colisão com veículos existentes (10m)
    local minVehDistSq = 100  -- 10 metros squared
    for vehicle, _ in pairs(self.activeVehicles) do
        if isElement(vehicle) then
            local vx, vy, vz = getElementPosition(vehicle)
            local dist = (vx - spawnX)^2 + (vy - spawnY)^2
            if dist < minVehDistSq then
                return 
            end
        end
    end
    
    -- Validar tipo para selecionar conexão inicial correta
    local allowedType = (spawnType == "ped") and 1 or 2
    
    -- Obter vizinho e conexão (sem exclusão de anterior pois é start, mas com check de tipo)
    local targetNode, targetID, conn = TrafficMap:getInstance():getRandomNeighbor(nodeID, nil, allowedType, false)
    if not targetNode then
        -- Node isolado ou tipo errado (carro em node de ped)
        -- outputDebugString("Node invalid for " .. spawnType .. " (ID: " .. nodeID .. ")")
        return
    end
    
    local heading = TrafficMap:getInstance():calculateHeading(nodeID, targetID)
    
    -- Spawnar!
    outputDebugString("SUCCESS: Spawning " .. spawnType .. " at node " .. nodeID .. " -> " .. targetID)
    
    -- ===============================================
    -- LEGACY SPAWN LOGIC (generate.lua lines 450-473)
    -- ===============================================
    local map = TrafficMap:getInstance()
    local n1 = nodeID
    local n2 = targetID
    local nb = conn.nb  -- Bend node (curva)
    
    -- Lane: usar faixa da direita se existir
    local rl = conn.lanes and conn.lanes.right or 1
    local lane = (rl > 0) and 1 or 0
    
    -- Obter posições das extremidades
    local x1, y1, z1 = map:getLanePosition(n1, conn, lane, false)
    local x2, y2, z2 = map:getLanePosition(n2, conn, lane, true)
    
    -- Calcular vetor e distâncias
    local dx, dy, dz = x2 - x1, y2 - y1, z2 - z1
    local dist2D = math.sqrt(dx*dx + dy*dy)
    local dist3D = math.sqrt(dx*dx + dy*dy + dz*dz)
    
    -- Pitch (inclinação)
    local rx = math.deg(math.atan2(dz, dist2D))
    
    -- Calcular posição e rotação (LEGACY EXACT)
    local x, y, z, rz
    local connpos = 0.3 + math.random() * 0.4  -- 30-70% do caminho
    
    if nb then
        -- CURVA: Usar matemática de bend
        local node_nb = map.nodes[nb]
        if node_nb then
            local bx, by, bz = node_nb.x, node_nb.y, (z1+z2)*0.5
            local lx1, ly1, lz1 = x1-bx, y1-by, z1-bz
            local lx2, ly2, lz2 = x2-bx, y2-by, z2-bz
            local possin, poscos = math.sin(connpos), math.cos(connpos)
            x = bx + possin*lx1 + poscos*lx2
            y = by + possin*ly1 + poscos*ly2
            z = bz + possin*lz1 + poscos*lz2
            local tx = -poscos
            local ty = possin
            tx, ty = lx1*tx + lx2*ty, ly1*tx + ly2*ty
            rz = -math.deg(math.atan2(tx, ty))
        else
            -- Fallback para reta
            x = x1*(1-connpos) + x2*connpos
            y = y1*(1-connpos) + y2*connpos
            z = z1*(1-connpos) + z2*connpos
            rz = -math.deg(math.atan2(dx, dy))
        end
    else
        -- RETA: Interpolação linear simples
        x = x1*(1-connpos) + x2*connpos
        y = y1*(1-connpos) + y2*connpos
        z = z1*(1-connpos) + z2*connpos
        rz = -math.deg(math.atan2(dx, dy))
    end
    
    local heading = rz

    -- Velocidade (LEGACY)
    local maxSpeed = conn.maxspeed or 50
    local speedMPS = maxSpeed / 180
    local vmult = speedMPS / dist3D
    local vx, vy, vz = dx*vmult, dy*vmult, dz*vmult
    
    -- Dimension do player
    local dim = getElementDimension(player)

    if spawnType == "ped" then
        -- 20% chance de bicicleta, 80% a pé
        if math.random() < 0.20 then
            -- BICICLETA
            local bicycles = {509, 510, 481}  -- Bike, Mountain Bike, BMX
            local bikeModel = bicycles[math.random(#bicycles)]
            local zoff = (z_offset and z_offset[bikeModel]) or 0.5
            local finalZ = z + zoff + 0.3
            
            local bike = createVehicle(bikeModel, x, y, finalZ, 0, 0, heading)
            if bike then
                local skinModel = self:getRandomModel("ped")
                local rider = createPed(skinModel, x, y, finalZ + 1, heading)
                if rider then
                    warpPedIntoVehicle(rider, bike)
                    setElementData(bike, "traffic:managed", true)
                    setElementData(rider, "traffic:managed", true)
                    
                    self:registerEntity(bike, player)
                    setElementSyncer(bike, player)
                    
                    -- Enable HLC para o ciclista
                    local npc_hlc = getResourceFromName("npc_hlc")
                    if npc_hlc and getResourceState(npc_hlc) == "running" then
                        call(npc_hlc, "enableHLCForNPC", rider, "walk", 0.99, 25/180)
                    end
                end
            end
        else
            -- PEDESTRE A PÉ
            local model = self:getRandomModel("ped")
            local finalZ = z + 1.0
            
            local ped = TrafficPed:new(model, x, y, finalZ, heading)
            if ped then
                ped:enableHLC("walk")
                ped:startRoute(nodeID, targetID, conn)
                self:registerEntity(ped.element, player)
                setElementSyncer(ped.element, player)
            end
        end
    
    else
        -- SPAWNAR CARRO
        local model = self:getRandomModel("car")
        
        -- Z OFFSET (Legacy calculation - works on server)
        local modelZOff = (z_offset and z_offset[model]) or 1.0
        local finalZOffset = (modelZOff + 0.2) / math.cos(math.rad(rx))
        local finalZ = z + finalZOffset
        
        -- Criar Veículo Principal
        local vehicle = TrafficVehicle:new(model, x, y, finalZ, rx, 0, heading)
        
        if vehicle then
            -- Setar Dimension (como Legacy)
            setElementDimension(vehicle.element, dim)
            
            -- Setar Velocidade (Legacy Lines 690)
            setElementVelocity(vehicle.element, vx, vy, vz)
            
            -- Spawn Driver
            vehicle:spawnDriver(0, nodeID, targetID, conn, speedMPS) 
            
            self:registerEntity(vehicle.element, player)
            setElementSyncer(vehicle.element, player)
            
            -- TRAILERS (Legacy Lines 631+)
            local category = "NORMAL" -- TODO: Implement getVehicleCategory
            if model == 514 or model == 515 then category = "HEAVY" end
            
            if category == "HEAVY" and math.random() < 0.4 then
                local trailers = {435, 450, 584, 590, 591, 592, 593}
                local trailerModel = trailers[math.random(#trailers)]
                
                -- Spawn trailer atrás do caminhão
                local backX = x - (dx/dist2D)*8
                local backY = y - (dy/dist2D)*8
                
                local trailer = createVehicle(trailerModel, backX, backY, finalZ, rx, 0, heading)
                if trailer then
                    attachTrailerToVehicle(vehicle.element, trailer)
                    self:registerEntity(trailer, player)
                end
            end

            -- TOWTRUCKS
            if model == 525 and math.random() < 0.4 then
                 local towable_cars = {400, 401, 404}
                 local towedModel = towable_cars[math.random(#towable_cars)]
                 local backX = x - (dx/dist2D)*6
                 local backY = y - (dy/dist2D)*6
                 
                 local towed = createVehicle(towedModel, backX, backY, finalZ, rx, 0, heading)
                 if towed then
                     attachTrailerToVehicle(vehicle.element, towed)
                     self:registerEntity(towed, player)
                 end
            end
        end
    end
    
    self.occupiedNodes = self.occupiedNodes or {}
    self.occupiedNodes[nodeID] = true
    setTimer(function() if self.occupiedNodes then self.occupiedNodes[nodeID] = nil end end, 5000, 1)    
end

function TrafficManager:getRandomModel(spawnType)
    if spawnType == "ped" then
        -- Lista de skins comuns (civis)
        local skins = {7, 9, 10, 11, 12, 13, 14, 15, 17, 20, 21, 22, 23, 24, 25, 26, 28, 29, 30, 32, 33, 34, 35, 36, 37, 40, 41, 43, 44, 46, 47, 48, 55, 56, 57, 58, 59, 60, 68, 69, 70, 72, 73, 76, 78, 79, 82, 83, 84, 91, 93, 120, 121, 122, 123}
        return skins[math.random(#skins)]
    else
        -- Lista de carros comuns + CAMINHOES (514, 515) + TOWTRUCK (525)
        local vehicles = {400, 401, 404, 410, 412, 496, 500, 516, 517, 518, 436, 439, 445, 600, 589, 587, 560, 559, 540, 514, 515, 525}
        return vehicles[math.random(#vehicles)]
    end
end

function TrafficManager:registerEntity(entity, player)
    local syncer = player or getElementSyncer(entity)
    
    if getElementType(entity) == "vehicle" then
        self.activeVehicles[entity] = { created_at = getTickCount(), syncer = syncer }
    elseif getElementType(entity) == "ped" then
        self.activePeds[entity] = { created_at = getTickCount() }
    end
end

function TrafficManager:onVehicleDestroyed(vehicle)
    if self.activeVehicles[vehicle] then
        self.totalNPCCount = math.max(0, (self.totalNPCCount or 0) - 1)
    end
    self.activeVehicles[vehicle] = nil
end

function TrafficManager:onPedDestroyed(ped)
    if self.activePeds[ped] then
        self.totalNPCCount = math.max(0, (self.totalNPCCount or 0) - 1)
    end
    self.activePeds[ped] = nil
end

function TrafficManager:startGarbageCollector()
    setTimer(function() self:collectGarbage() end, self.config.gcInterval, 0)
end

function TrafficManager:collectGarbage()
    -- Remover veículos longe de todos os players
    local maxDist = self.config.despawnDistance or 400
    local maxDistSq = maxDist * maxDist
    local freezeDist = self.config.freezeDistance or 250
    local freezeDistSq = freezeDist * freezeDist
    local players = getElementsByType("player")
    
    -- Processar VEÍCULOS primeiro
    for vehicle, _ in pairs(self.activeVehicles) do
        if not isElement(vehicle) then
            self.activeVehicles[vehicle] = nil
        else
            local ex, ey, ez = getElementPosition(vehicle)
            local minDistSq = math.huge
            
            for _, player in ipairs(players) do
                local px, py, pz = getElementPosition(player)
                local distSq = (px-ex)^2 + (py-ey)^2
                if distSq < minDistSq then
                    minDistSq = distSq
                end
            end
            
            if minDistSq > maxDistSq then
                -- Destruir OCUPANTES primeiro (Legacy pattern)
                local occupants = getVehicleOccupants(vehicle)
                if occupants then
                    for seat, ped in pairs(occupants) do
                        if isElement(ped) then
                            destroyElement(ped)
                        end
                    end
                end
                -- Depois destruir veículo
                destroyElement(vehicle)
            elseif minDistSq > freezeDistSq then
                if not isElementFrozen(vehicle) then
                    setElementFrozen(vehicle, true)
                end
            else
                if isElementFrozen(vehicle) then
                    setElementFrozen(vehicle, false)
                end
            end
        end
    end
    
    -- Processar PEDS (a pé, não em veículo)
    for ped, _ in pairs(self.activePeds) do
        if not isElement(ped) then
            self.activePeds[ped] = nil
        elseif not isPedInVehicle(ped) then
            local ex, ey, ez = getElementPosition(ped)
            local minDistSq = math.huge
            
            for _, player in ipairs(players) do
                local px, py, pz = getElementPosition(player)
                local distSq = (px-ex)^2 + (py-ey)^2
                if distSq < minDistSq then
                    minDistSq = distSq
                end
            end
            
            if minDistSq > maxDistSq then
                destroyElement(ped)
            elseif minDistSq > freezeDistSq then
                if not isElementFrozen(ped) then
                    setElementFrozen(ped, true)
                end
            else
                if isElementFrozen(ped) then
                    setElementFrozen(ped, false)
                end
            end
        end
    end
end

return TrafficManager:getInstance()
