--[[
    NPCSensorSystem.lua
    Full sensor system for NPC vehicles - ported from legacy generate.lua
    Provides collision avoidance, following behavior, and brake control
]]

NPCSensorSystem = {}
NPCSensorSystem.__index = NPCSensorSystem

-- Singleton
local instance = nil

-- Configuration constants (from legacy)
local SENSOR_DISTANCE = 25      -- metros para detectar obstáculos
local SIDE_SENSOR_DISTANCE = 8  -- metros para sensores laterais
local BRAKE_DISTANCE = 8        -- metros para frear forte
local FOLLOW_DISTANCE = 15      -- metros para seguir veículo da frente

function NPCSensorSystem:getInstance()
    if not instance then
        instance = setmetatable({}, NPCSensorSystem)
    end
    return instance
end

function NPCSensorSystem:init()
    if self.initialized then return end
    
    self.npc_sensors = {}
    
    -- Timer para verificar sensores (como legacy)
    setTimer(function()
        self:processSensorTick()
    end, 500, 0)  -- A cada 500ms
    
    -- Cleanup quando NPC é destruído
    addEventHandler("onElementDestroy", root, function()
        if getElementType(source) == "ped" then
            self:cleanup(source)
        end
    end)
    
    outputDebugString("[NPCSensorSystem] Initialized with legacy sensor logic.")
    self.initialized = true
end

-- Inicializar sensores para um NPC (legacy: initNPCSensors)
function NPCSensorSystem:registerNPC(ped, vehicle, originalSpeed)
    if not ped or not vehicle then return end
    
    -- Aguardar HLC inicializar primeiro (como legacy)
    setTimer(function()
        if isElement(ped) and isElement(vehicle) then
            self.npc_sensors[ped] = {
                vehicle = vehicle,
                front_clear = true,
                left_clear = true,
                right_clear = true,
                following_vehicle = nil,
                last_check = 0,
                brake_intensity = 0,
                original_speed = originalSpeed or 0.8,
                hlc_controlled = true
            }
        end
    end, 1500, 1)
end

-- Timer principal de processamento
function NPCSensorSystem:processSensorTick()
    for ped, _ in pairs(self.npc_sensors) do
        if isElement(ped) and getElementType(ped) == "ped" and isPedInVehicle(ped) then
            self:checkObstacles(ped)
        else
            self.npc_sensors[ped] = nil
        end
    end
end

-- Verificar obstáculos (legacy: checkNPCObstacles)
function NPCSensorSystem:checkObstacles(ped)
    local sensor_data = self.npc_sensors[ped]
    if not sensor_data or not isElement(sensor_data.vehicle) then return end
    
    local current_time = getTickCount()
    if current_time - sensor_data.last_check < 500 then return end
    sensor_data.last_check = current_time
    
    local vehicle = sensor_data.vehicle
    local vx, vy, vz = getElementPosition(vehicle)
    local _, _, rz = getElementRotation(vehicle)
    local dim = getElementDimension(vehicle)
    
    -- Calcular direção frontal
    local rad = math.rad(rz)
    local forwardX = -math.sin(rad)
    local forwardY = math.cos(rad)
    
    -- Verificar sensor frontal
    local front_hit = false
    local closest_distance = SENSOR_DISTANCE
    local following_target = nil
    
    -- Usar getElementsWithinRange para detectar TODOS os veículos (como legacy)
    local nearby_vehicles = getElementsWithinRange(vx, vy, vz, SENSOR_DISTANCE, "vehicle", dim)
    
    for _, other_vehicle in ipairs(nearby_vehicles or {}) do
        if other_vehicle ~= vehicle and isElement(other_vehicle) then
            local ox, oy, oz = getElementPosition(other_vehicle)
            local dx, dy = ox - vx, oy - vy
            local distance = math.sqrt(dx*dx + dy*dy)
            
            if distance < SENSOR_DISTANCE and distance > 0.5 then
                -- Verificar se está na frente (dot product)
                local dot = (dx * forwardX + dy * forwardY) / distance
                
                -- Se dentro do cone frontal (45 graus = dot > 0.7)
                if dot > 0.7 and distance < closest_distance then
                    front_hit = true
                    closest_distance = distance
                    following_target = other_vehicle
                end
            end
        end
    end
    
    -- Também verificar peds/players
    local nearby_peds = getElementsWithinRange(vx, vy, vz, SENSOR_DISTANCE, "ped", dim)
    for _, other_ped in ipairs(nearby_peds or {}) do
        if other_ped ~= ped and isElement(other_ped) then
            local ox, oy, oz = getElementPosition(other_ped)
            local dx, dy = ox - vx, oy - vy
            local distance = math.sqrt(dx*dx + dy*dy)
            
            if distance < BRAKE_DISTANCE and distance > 0.5 then
                local dot = (dx * forwardX + dy * forwardY) / distance
                if dot > 0.5 then  -- Pedestre na frente
                    front_hit = true
                    if distance < closest_distance then
                        closest_distance = distance
                    end
                end
            end
        end
    end
    
    sensor_data.front_clear = not front_hit
    sensor_data.following_vehicle = following_target
    
    -- Aplicar comportamento baseado nos sensores
    self:applyBehavior(ped, sensor_data, closest_distance)
end

-- Aplicar comportamento (legacy: applyNPCSensorBehavior)
function NPCSensorSystem:applyBehavior(ped, sensor_data, obstacle_distance)
    if not isElement(ped) or not isElement(sensor_data.vehicle) then return end
    
    if not sensor_data.front_clear then
        if obstacle_distance < BRAKE_DISTANCE then
            -- PARAR! Obstáculo muito perto
            setElementData(ped, "hlc_brake_signal", true)
            setElementData(ped, "hlc_target_speed", 0.05)  -- Quase parado
            sensor_data.brake_intensity = 1.0
            
        elseif obstacle_distance < FOLLOW_DISTANCE and sensor_data.following_vehicle then
            -- Seguir veículo da frente
            local speed_factor = obstacle_distance / FOLLOW_DISTANCE
            local target_speed = 0.2 + speed_factor * 0.4
            setElementData(ped, "hlc_brake_signal", false)
            setElementData(ped, "hlc_target_speed", target_speed)
            sensor_data.brake_intensity = 0.3
            
        else
            -- Reduzir velocidade gradualmente
            local speed_factor = obstacle_distance / SENSOR_DISTANCE
            local target_speed = 0.3 + speed_factor * 0.5
            setElementData(ped, "hlc_brake_signal", false)
            setElementData(ped, "hlc_target_speed", target_speed)
            sensor_data.brake_intensity = 0.1
        end
    else
        -- Caminho livre - velocidade normal
        setElementData(ped, "hlc_brake_signal", false)
        setElementData(ped, "hlc_target_speed", sensor_data.original_speed)
        sensor_data.brake_intensity = 0
    end
    
    -- Aplicar velocidade ao HLC
    self:updateHLCSpeed(ped)
end

-- Atualizar velocidade no HLC
function NPCSensorSystem:updateHLCSpeed(ped)
    local target_speed = getElementData(ped, "hlc_target_speed")
    if not target_speed then return end
    
    local npc_hlc = getResourceFromName("npc_hlc")
    if npc_hlc and getResourceState(npc_hlc) == "running" then
        pcall(function()
            call(npc_hlc, "setNPCDriveSpeed", ped, target_speed)
        end)
    end
end

-- Limpar sensores
function NPCSensorSystem:cleanup(ped)
    if self.npc_sensors[ped] then
        removeElementData(ped, "hlc_brake_signal")
        removeElementData(ped, "hlc_target_speed")
        self.npc_sensors[ped] = nil
    end
end

-- Função global para fácil acesso
function initNPCSensors(ped, vehicle, speed)
    NPCSensorSystem:getInstance():registerNPC(ped, vehicle, speed)
end
