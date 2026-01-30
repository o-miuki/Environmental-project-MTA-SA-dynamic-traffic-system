--[[
    TrafficPed.lua
    Wrapper for traffic pedestrians (drivers or walkers).
    Handles HLC initialization and state.
]]

TrafficPed = {}
TrafficPed.__index = TrafficPed

function TrafficPed:new(model, x, y, z, rz, dimension)
    local self = setmetatable({}, TrafficPed)
    
    self.element = createPed(model, x, y, z, rz)
    if not self.element then return nil end
    
    if dimension then setElementDimension(self.element, dimension) end
    
    setElementData(self.element, "traffic:managed", true)
    
    -- Configuração inicial do NPC HLC
    -- Em sistema moderno, isso seria um método da classe, mas mantemos compatibilidade
    -- com os exports do recurso npc_hlc por enquanto
    
    return self
end

function TrafficPed:enableHLC(walkSpeed, accuracy, driveSpeed)
    -- Wrapper para o sistema NPC HLC existente
    local npc_hlc = getResourceFromName("npc_hlc")
    if npc_hlc and getResourceState(npc_hlc) == "running" then
        if not call(npc_hlc, "isHLCEnabled", self.element) then
            -- enableHLCForNPC(npc, walk_speed, accuracy, drive_speed)
            
            local wSpeed = (type(walkSpeed) == "string") and walkSpeed or "run"
            local acc = (type(accuracy) == "number") and accuracy or 0.9
            local dSpeed = (type(driveSpeed) == "number") and driveSpeed or (40/180)
            
            call(npc_hlc, "enableHLCForNPC", self.element, wSpeed, acc, dSpeed) 
        end
    end
end



function TrafficPed:startRoute(n1_id, n2_id, conn)
    self.currentNode = n1_id
    self.nextNode = n2_id
    self.currentConn = conn
    
    -- Bufferizar movimentos iniciais (como no legacy code: 1 + 1 + 4)
    self:addNextTask() -- 1st segment (start -> next)
    
    -- Adicionar mais tarefas futuras para garantir fluidez
    for i = 1, 4 do
        self:continueRoute()
    end
    
    -- Registrar evento para repor tarefas conforme forem acabando
    if not self.eventHandlerAdded then
        addEventHandler("npc_hlc:onNPCTaskDone", self.element, function()
            self:continueRoute()
        end)
        self.eventHandlerAdded = true
    end
end

function TrafficPed:addNextTask()
    if not self.currentNode or not self.nextNode then return end
    
    local map = TrafficMap:getInstance()
    local n1 = map.nodes[self.currentNode]
    local n2 = map.nodes[self.nextNode]
    local conn = self.currentConn
    
    if n1 and n2 then
        local npc_hlc = getResourceFromName("npc_hlc")
        local vehicle = getPedOccupiedVehicle(self.element)
        local lane = 1 -- Default right lane
        
        -- Calcular posições exatas da lane
        local x1, y1, z1 = map:getLanePosition(self.currentNode, conn, lane, false)
        local x2, y2, z2 = map:getLanePosition(self.nextNode, conn, lane, true)

        -- Verificar se tem curva (Note Bend - nb)
        local nb = conn and conn.nb and map.nodes[conn.nb]
        
        if vehicle then
            local offset = 8.0 -- Lookahead distance (evita zig-zag)
            if nb then
                -- driveAroundBend (bendX, bendY, x1, y1, z1, x2, y2, z2, offset, endDist)
                call(npc_hlc, "addNPCTask", self.element, {"driveAroundBend", nb.x, nb.y, x1, y1, z1, x2, y2, z2, offset, 5.0})
            else
                -- driveAlongLine
                call(npc_hlc, "addNPCTask", self.element, {"driveAlongLine", x1, y1, z1, x2, y2, z2, offset, 5.0})
            end
        else
            local offset = 1.0 -- Peds precisam de offset menor
            if nb then
                -- walkAroundBend (bendX, bendY, x1, y1, z1, x2, y2, z2, width, endDist)
                call(npc_hlc, "addNPCTask", self.element, {"walkAroundBend", nb.x, nb.y, x1, y1, z1, x2, y2, z2, 0.5, offset})
            else
                -- walkAlongLine
                call(npc_hlc, "addNPCTask", self.element, {"walkAlongLine", x1, y1, z1, x2, y2, z2, 0.5, offset})
            end
        end
    end
end

function TrafficPed:continueRoute()
    -- Avançar um passo no grafo
    if not self.nextNode then return end
    
    self.previousNode = self.currentNode -- Guardar de onde viemos
    self.currentNode = self.nextNode
    
    local map = TrafficMap:getInstance()
    
    -- Determinar restrições baseadas no tipo de NPC (Carro vs Ped)
    local vehicle = getPedOccupiedVehicle(self.element)
    local allowedType = vehicle and 2 or 1 -- 2=Car, 1=Ped
    local checkDirection = (vehicle ~= nil) -- Só carros precisam verificar fluxo de trânsito
    
    -- Pedir vizinho com restrições
    local targetNode, targetID, conn = map:getRandomNeighbor(self.currentNode, self.previousNode, allowedType, checkDirection)
    
    if targetNode then
        self.nextNode = targetID
        self.currentConn = conn
        self:addNextTask()
    else
        -- Fim da linha (sem vizinhos)
        self.nextNode = nil
    end
end

function TrafficPed:assignToVehicle(vehicleElement, seat)
    warpPedIntoVehicle(self.element, vehicleElement, seat or 0)
end

function TrafficPed:destroy()
    if isElement(self.element) then
        destroyElement(self.element)
    end
end



-- Ported from ai.lua
local function calculateTurnAngle(x1, y1, x2, y2, x3, y3)
    local vec1_x, vec1_y = x2 - x1, y2 - y1
    local vec2_x, vec2_y = x3 - x2, y3 - y2
    
    local len1 = math.sqrt(vec1_x^2 + vec1_y^2)
    local len2 = math.sqrt(vec2_x^2 + vec2_y^2)
    
    if len1 == 0 or len2 == 0 then return 0, 0 end
    
    vec1_x, vec1_y = vec1_x / len1, vec1_y / len1
    vec2_x, vec2_y = vec2_x / len2, vec2_y / len2
    
    local cross = vec1_x * vec2_y - vec1_y * vec2_x
    local dot = vec1_x * vec2_x + vec1_y * vec2_y
    local angle = math.acos(math.max(-1, math.min(1, dot)))
    
    return math.deg(angle), cross -- degrees, cross product (sign determines left/right)
end

function TrafficPed:analyzeUpcomingTurn(vehicle)
    if not self.currentNode or not self.nextNode then return end
    
    local map = TrafficMap:getInstance()
    local n1 = map.nodes[self.currentNode]
    local n2 = map.nodes[self.nextNode]
    
    -- Precisamos saber o "próximo do próximo" para calcular o ângulo
    -- Como TrafficPed não tem fila futura, vamos simular uma escolha
    -- Ou melhor: Apenas se já tivermos escolhido.
    -- Como addNextTask é chamado APÓS continueRoute, self.nextNode já é o alvo.
    -- O "futuro" node ainda não foi decidido.
    -- Mas espera, addNextTask é chamado para EXECUTAR o movimento ATUAL.
    -- O turn signal deve ser ligado ANTES da curva.
    -- Ou seja, quando estamos indo de A -> B, e B é uma esquina, devemos ligar a seta para B -> C.
    -- Mas aqui estamos configurando A -> B. A seta seria para a curva em B?
    -- Se A -> B é longo, ligamos a seta perto de B?
    -- O código original chama analyzeUpcomingTurn no "continuePedRoute".
    -- "ped_thisnode" + 1 + 2.
    -- Ele olha 2 nodes à frente.
    
    -- Simplificação: Vamos ligar a seta se o ângulo entre currentConn e nextConn for alto.
    -- Mas nextConn ainda não existe.
    -- Solução: Só ligamos a seta se já estivermos chegando no fim?
    -- Melhor: Ao iniciar A -> B, olhamos se A era uma curva? Não.
    
    -- Vamos deixar para a próxima iteração do continueRoute.
    -- Mas precisamos armazenar o node anterior para ter 3 pontos (Prev -> Curr -> Next).
    
    -- SISTEMA DE SETAS DESATIVADO TEMPORARIAMENTE
    -- Problema: Ativa cedo demais e direção invertida
    -- TODO: Reimplementar com lógica de distância ao ponto de curva
    --[[
    if self.previousNode and self.currentNode and self.nextNode then
        local n0 = map.nodes[self.previousNode]
        local n1 = map.nodes[self.currentNode]
        local n2 = map.nodes[self.nextNode]
        
        if n0 and n1 and n2 then
             local angle, cross = calculateTurnAngle(n0.x, n0.y, n1.x, n1.y, n2.x, n2.y)
             
             if angle > 20 then
                local turnLeft = (cross > 0)
                
                if getElementData(vehicle, "turn_left") ~= turnLeft then
                    setElementData(vehicle, "turn_left", turnLeft)
                    setElementData(vehicle, "turn_right", not turnLeft)
                    setElementData(vehicle, "emergency_light", false)
                    
                    setTimer(function(v)
                        if isElement(v) then
                            setElementData(v, "turn_left", false)
                            setElementData(v, "turn_right", false)
                        end
                    end, 4000, 1, vehicle)
                end
             end
        end
    end
    ]]
end

function TrafficPed:addNextTask()
    if not self.currentNode or not self.nextNode then return end
    
    local map = TrafficMap:getInstance()
    local n1 = map.nodes[self.currentNode]
    local n2 = map.nodes[self.nextNode]
    local conn = self.currentConn
    
    if n1 and n2 then
        local npc_hlc = getResourceFromName("npc_hlc")
        local vehicle = getPedOccupiedVehicle(self.element)
        local lane = 1 -- Default right lane
        
        -- Calcular posições exatas da lane
        local x1, y1, z1 = map:getLanePosition(self.currentNode, conn, lane, false)
        local x2, y2, z2 = map:getLanePosition(self.nextNode, conn, lane, true)

        -- Verificar se tem curva (Note Bend - nb)
        local nb = conn and conn.nb and map.nodes[conn.nb]
        
        -- 1. Traffic Light Logic
        -- Check if current connection has a light at the START node (n1).
        -- Legacy logic was: if nodeid == conn_n1 then light1 else light2.
        -- We stored 'light' in conn. But wait, we need to know WHICH light.
        -- For now, assume conn.light applies to the intersection we are approaching?
        -- Actually, lights usually block entry to an intersection.
        -- If we are at N1 going to N2, we check light at N1? 
        -- Or is it light at N2? Usually you stop at the stop line BEFORE N2.
        -- But the legacy code did: call(npc_hlc, "addNPCTask", ..., {"waitForGreenLight", lights})
        -- AFTER setting the move task? No, BEFORE or AFTER?
        -- Legacy: line 139: if lights then call(..., "waitForGreenLight") END.
        -- It adds the task AFTER the move task? That implies "Wait for green light AFTER moving"?
        -- That sounds wrong. Unless "waitForGreenLight" is a condition for the NEXT move?
        -- Or maybe "Move until point X, then wait".
        -- "driveAlongLine" is asynchronous? No, tasks are queued.
        -- If I add "Wait" then "Drive", he waits then drives.
        -- Legacy adds "Drive" then "Wait".
        -- Wait, line 140: call(..., "waitForGreenLight") is the LAST call in addNodeToPedRoute.
        -- So he drives segment A->B, then waits for light at B? Yes.
        -- That makes sense. You drive TO the intersection, then STOP if red.
        
        if vehicle then
            -- Turn Signals (Seta) - Revertido para Lógica Legacy (cross < 0 = Left Data)
            -- Aparentemente o Client/Model espera isso.
            self:analyzeUpcomingTurn(vehicle)
        
            local offset = 8.0 -- Lookahead distance
            local endDist = 10.0 -- Aumentado para 10.0 (Legacy usa boxY2+5 ~ 7-10m).
            -- Isso faz o carro parar ANTES do cruzamento.
            
            if nb then
                -- driveAroundBend (bendX, bendY, x1, y1, z1, x2, y2, z2, offset, endDist)
                call(npc_hlc, "addNPCTask", self.element, {"driveAroundBend", nb.x, nb.y, x1, y1, z1, x2, y2, z2, offset, endDist})
            else
                -- driveAlongLine
                call(npc_hlc, "addNPCTask", self.element, {"driveAlongLine", x1, y1, z1, x2, y2, z2, offset, endDist})
            end
        else
            local offset = 1.0 -- Peds precisam de offset menor
            if nb then
                -- walkAroundBend (bendX, bendY, x1, y1, z1, x2, y2, z2, width, endDist)
                call(npc_hlc, "addNPCTask", self.element, {"walkAroundBend", nb.x, nb.y, x1, y1, z1, x2, y2, z2, 0.5, offset})
            else
                -- walkAlongLine
                call(npc_hlc, "addNPCTask", self.element, {"walkAlongLine", x1, y1, z1, x2, y2, z2, 0.5, offset})
            end
        end
        
        -- TRAFFIC LIGHT DISABLED TEMPORARILY
        -- A lógica atual está fazendo NPCs pararem no semáforo da faixa contrária.
        -- TODO: Reimplementar verificando se o light pertence à conexão específica.
        --[[ 
        if conn and conn.light and conn.light > 0 then
             local lightDir = "NS"
             
             if not vehicle then
                 lightDir = "ped"
             else
                 local heading = map:calculateHeading(self.currentNode, self.nextNode)
                 heading = (heading % 360 + 360) % 360
                 
                 if (heading >= 315 or heading < 45) or (heading >= 135 and heading < 225) then
                     lightDir = "NS"
                 else
                     lightDir = "WE"
                 end
             end
             
             call(npc_hlc, "addNPCTask", self.element, {"waitForGreenLight", lightDir})
        end
        ]]
    end
end

return TrafficPed
