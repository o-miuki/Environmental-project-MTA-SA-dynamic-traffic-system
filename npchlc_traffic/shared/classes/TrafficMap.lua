--[[
    TrafficMap.lua
    Shared class for handling Traffic Paths/Graphs.
    Parsed from binary files (same format as original load_paths.lua).
]]

TrafficMap = {}
TrafficMap.__index = TrafficMap

-- Singleton
local instance = nil

function TrafficMap:getInstance()
    if not instance then
        instance = setmetatable({}, TrafficMap)
    end
    return instance
end

function TrafficMap:init()
    if self.initialized then return end
    
    self.nodes = {} -- {x, y, z, rx, ry}
    self.connections = {} -- Graph structure
    self.spatialGrid = {} -- Optimization for spatial queries
    
    local success = self:loadAllMaps()
    if success then
        self:calculateNodeLanes() -- Calcular geometria das faixas
        outputDebugString("[TrafficMap] Loaded successfully. Nodes: " .. #self.nodes)
        self.initialized = true
    end
end

function TrafficMap:loadAllMaps()
    local maplist = xmlLoadFile("paths/maplist.xml")
    if not maplist then return false end
    
    local children = xmlNodeGetChildren(maplist)
    for _, node in ipairs(children) do
        local filename = xmlNodeGetAttribute(node, "src")
        if filename then
            self:loadMapFile("paths/maps/" .. filename)
        end
    end
    xmlUnloadFile(maplist)
    return true
end

-- Fork of loadPathMapFile adapted for OOP
function TrafficMap:loadMapFile(filename)
    if not fileExists(filename) then return end
    
    local file = fileOpen(filename, true)
    if not file then return end
    
    local header = fileRead(file, 12)
    local nodecount, conncount, forbcount = self:bytesToData("3i", header)
    
    -- Load Nodes
    local current_node_offset = #self.nodes
    local local_node_ids = {} -- Map file ID -> Global ID
    
    for i = 1, nodecount do
        local bytes = fileRead(file, 16)
        local x,y,z,rx,ry = self:bytesToData("3i2s", bytes)
        local id = current_node_offset + i
        
        self.nodes[id] = {
            id = id,
            x = x/1000, y = y/1000, z = z/1000,
            rx = rx/1000, ry = ry/1000,
            conns = {}
        }
        local_node_ids[i] = id
    end
    
    -- Load Connections
    for i = 1, conncount do
        local bytes = fileRead(file, 20)
        local n1,n2,nb,trtype,lit,speed,ll,rl,density = self:bytesToData("3i2ubus2ubus", bytes)
        
        -- Mapping local IDs to global
        n1 = local_node_ids[n1]
        n2 = local_node_ids[n2]
        nb = (nb ~= -1) and local_node_ids[nb] or nil
        
        local conn = {
            n1 = n1, n2 = n2, nb = nb,
            type = trtype, -- 1:ped, 2:car, 3:boat, 4:plane
            light = lit,   -- Traffic Light ID
            maxspeed = speed/10,
            lanes = {left = ll, right = rl},
            density = density/1000
        }
        
        table.insert(self.connections, conn)
        
        -- Add to node adjacency
        table.insert(self.nodes[n1].conns, conn)
        table.insert(self.nodes[n2].conns, conn)
    end
    
    fileClose(file)
end

-- Helper for binary data (from bytedata.lua equivalent)
function TrafficMap:bytesToData(format, data)
    -- Requires bytedata.lua global functions (bytesToData)
    -- We assume bytedata.lua is loaded in meta.xml before this
    return bytesToData(format, data)
end

function TrafficMap:getNodesInRange(x, y, range)
    -- TODO: Implement proper spatial hashing for performance
    -- For now, simple iteration (slow for 10k nodes, need optimization later)
    local result = {}
    local range2 = range * range
    for _, node in ipairs(self.nodes) do
        local dist2 = (node.x - x)^2 + (node.y - y)^2
        if dist2 <= range2 then
            table.insert(result, node)
        end
    end
    return result
end

function TrafficMap:getRandomNeighbor(nodeID, excludeID, allowedType, checkDirection)
    local node = self.nodes[nodeID]
    if not node or not node.conns or #node.conns == 0 then return nil end
    
    -- Filtrar candidatos válidos
    local candidates = {}
    for _, conn in ipairs(node.conns) do
        local targetID = (conn.n1 == nodeID) and conn.n2 or conn.n1
        
        -- 1. Check Exclusion (Previous Node)
        local valid = (targetID ~= excludeID)
        
        -- 2. Check Type (Car vs Ped)
        if valid and allowedType then
            -- Se allowedType for tabela ou numero
            valid = (conn.type == allowedType)
        end

    -- 3. Check Direction (Flow preservation for cars) - Ported from ai.lua
        if valid and checkDirection then
            -- Logic: dirmatch1 == dirmatch2
            -- prev -> node (n1 -> n2 in dirmatch1 context?)
            -- node -> target (n2 -> n3 in dirmatch2 context)
            
            -- Precisamos saber de onde viemos (excludeID) para calcular o dirmatch1
            if excludeID then
                local prev = excludeID
                local curr = nodeID
                local next = targetID
                
                -- ai.lua: areDirectionsMatching(n2, n1, n2) == areDirectionsMatching(n2, n2, n3)
                -- aqui: areDirectionsMatching(curr, prev, curr) == areDirectionsMatching(curr, curr, next)
                
                local dm1 = self:areDirectionsMatching(curr, prev, curr)
                local dm2 = self:areDirectionsMatching(curr, curr, next)
                
                if dm1 ~= dm2 then
                    valid = false
                end
            end
        end
        
        if valid then
            table.insert(candidates, conn)
        end
    end
    
    -- Seleção Ponderada por Densidade (Weighted Random)
    if #candidates > 0 then
        local total_density = 0
        for _, c in ipairs(candidates) do
            total_density = total_density + (c.density or 1)
        end
        
        if total_density > 0 then
            local pos = math.random() * total_density
            for _, c in ipairs(candidates) do
                pos = pos - (c.density or 1)
                if pos <= 0 then
                    local targetID = (c.n1 == nodeID) and c.n2 or c.n1
                    return self.nodes[targetID], targetID, c
                end
            end
        end
        
        -- Fallback simples se algo der errado no loop de densidade
        local conn = candidates[math.random(#candidates)]
        local targetID = (conn.n1 == nodeID) and conn.n2 or conn.n1
        return self.nodes[targetID], targetID, conn
    end
    
    -- Se não houver candidatos E não for restrição de tipo (apenas direção/deadend),
    -- tentar relaxar a direção? Não, melhor travar ou dar u-turn se for beco.
    
    -- Se falhou por filtros mas temos conexões... (Dead End ou todos bloqueados)
    -- Recalcular apenas com filtro de tipo para escapar (Fallback de ai.lua)
    candidates = {}
    if allowedType then
         for _, conn in ipairs(node.conns) do
            if conn.type == allowedType then
                table.insert(candidates, conn)
            end
        end
    else
        candidates = node.conns
    end

    if #candidates == 0 then return nil end -- Realmente sem saida valida

    -- Escolher qualquer um para escapar
    local conn = candidates[math.random(#candidates)]
    
    -- Determinar qual é o "outro" node
    local targetID = (conn.n1 == nodeID) and conn.n2 or conn.n1
    
    -- Pegar coordenadas do alvo
    local targetNode = self.nodes[targetID]
    return targetNode, targetID, conn
end

function TrafficMap:calculateHeading(n1_id, n2_id)
    local n1 = self.nodes[n1_id]
    local n2 = self.nodes[n2_id]
    if not n1 or not n2 then return 0 end
    
    local dx = n2.x - n1.x
    local dy = n2.y - n1.y
    return math.deg(math.atan2(dx, dy)) * -1
end

-- ============================================================================
-- LANE LOGIC PORT (from node_lanes.lua)
-- ============================================================================

function TrafficMap:calculateNodeLanes()
    -- Inicializar arrays de lanes por node
    for id, node in pairs(self.nodes) do
        node.lanes = {left = 0, right = 0}
    end

    for _, conn in ipairs(self.connections) do
        local n1 = self.nodes[conn.n1]
        local n2 = self.nodes[conn.n2]
        local nb = conn.nb and self.nodes[conn.nb] or nil
        
        if not n1 or not n2 then break end -- continue

        local ll, rl = conn.lanes.left, conn.lanes.right
        
        local n1_match = self:areDirectionsMatching(conn.n1, conn.n1, conn.n2)
        if nb then n1_match = self:areDirectionsMatching(conn.n1, conn.n1, conn.nb) end
        
        if n1_match then
            if ll ~= 0 then n1.lanes.left = (n1.lanes.left == 0) and ll or math.min(ll, n1.lanes.left) end
            if rl ~= 0 then n1.lanes.right = (n1.lanes.right == 0) and rl or math.min(rl, n1.lanes.right) end
        else
            if rl ~= 0 then n1.lanes.left = (n1.lanes.left == 0) and rl or math.min(rl, n1.lanes.left) end
            if ll ~= 0 then n1.lanes.right = (n1.lanes.right == 0) and ll or math.min(ll, n1.lanes.right) end
        end

        local n2_match = self:areDirectionsMatching(conn.n2, conn.n1, conn.n2) 
        -- Nota: Logica original usa (n2, n1, nb or n2) no segundo param? 
        -- Original: areDirectionsMatching(n2,n1,nb or n2)
        local n2_target = nb and nb.id or conn.n2
        if nb then 
             n2_match = self:areDirectionsMatching(conn.n2, conn.n1, nb.id) 
        else
             n2_match = self:areDirectionsMatching(conn.n2, conn.n1, conn.n2)
        end
        
        -- Override manual para seguir logica exata do node_lanes.lua original se necessario
        -- Mas a logica geometrica de Matching deve resolver.
        
        if n2_match then
            if ll ~= 0 then n2.lanes.left = (n2.lanes.left == 0) and ll or math.min(ll, n2.lanes.left) end
            if rl ~= 0 then n2.lanes.right = (n2.lanes.right == 0) and rl or math.min(rl, n2.lanes.right) end
        else
            if rl ~= 0 then n2.lanes.left = (n2.lanes.left == 0) and rl or math.min(rl, n2.lanes.left) end
            if ll ~= 0 then n2.lanes.right = (n2.lanes.right == 0) and ll or math.min(ll, n2.lanes.right) end
        end
    end
end

function TrafficMap:getLanePosition(nodeID, conn, lane, isDest)
    local node = self.nodes[nodeID]
    if lane == 0 then return node.x, node.y, node.z end
    
    local n1 = conn.n1
    local n2 = conn.n2
    local nb = conn.nb
    
    local dirs_match = false
    
    if isDest then
        if nodeID ~= n1 then
             dirs_match = self:areDirectionsMatching(nodeID, n1, nb or n2)
        else
             dirs_match = self:areDirectionsMatching(nodeID, n2, nb or n1)
        end
    else
        if nodeID == n1 then
             dirs_match = self:areDirectionsMatching(nodeID, n1, nb or n2)
        else
             dirs_match = self:areDirectionsMatching(nodeID, n2, nb or n1)
        end
    end
    
    if dirs_match then
        return self:calculateOffset(node, "right", lane)
    else
        return self:calculateOffset(node, "left", lane)
    end
end

function TrafficMap:calculateOffset(node, side, lane)
    local x, y, z = node.x, node.y, node.z
    local rx, ry = node.rx, node.ry
    local ll, rl = node.lanes.left, node.lanes.right
    
    -- Math do arquivo original
    lane = math.min(lane, (side == "left") and ll or rl) * 2 - 1
    local lanepos = -(rl - ll) + ((side == "left") and -lane or lane)
    
    return x + rx * lanepos, y + ry * lanepos, z
end

function TrafficMap:areDirectionsMatching(n_id, n1_id, n2_id)
    local n = self.nodes[n_id]
    local n1 = self.nodes[n1_id]
    local n2 = self.nodes[n2_id]
    
    local rx, ry = n.rx, n.ry
    local cx, cy = n2.x - n1.x, n2.y - n1.y
    local nfx, nfy = -ry, rx
    
    return (cx * nfx + cy * nfy) > 0
end

return TrafficMap:getInstance()
