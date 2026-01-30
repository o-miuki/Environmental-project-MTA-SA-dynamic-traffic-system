--[[
    TrafficVehicle.lua
    Wrapper class for traffic vehicles.
    Handles trailers, passengers, and initialization.
]]

TrafficVehicle = {}
TrafficVehicle.__index = TrafficVehicle

function TrafficVehicle:new(model, x, y, z, rx, ry, rz)
    local self = setmetatable({}, TrafficVehicle)
    
    -- Criar elemento físico
    self.element = createVehicle(model, x, y, z, rx, ry, rz)
    
    if not self.element then return nil end
    
    self.model = model
    self.trailers = {}
    self.passengers = {}
    
    -- Configurar data inicial
    setElementData(self.element, "traffic:managed", true)
    
    return self
end

function TrafficVehicle:spawnDriver(initialTask, startNodeID, nextNodeID, conn, speed)
    local x, y, z = getElementPosition(self.element)
    
    -- Lista de skins (igual ao Legacy generate.lua)
    local skins = {7, 9, 10, 11, 12, 13, 14, 15, 17, 20, 21, 22, 23, 24, 25, 26, 28, 29, 30, 32, 33, 34, 35, 36, 37, 40, 41, 43, 44, 46, 47, 48, 55, 56, 57, 58, 59, 60, 68, 69, 70, 72, 73, 76, 78, 79, 82, 83, 84, 91, 93, 120, 121, 122, 123}
    
    -- Usar skin aleatória ao invés de CJ (0)
    local driverModel = skins[math.random(#skins)]
    local driver = TrafficPed:new(driverModel, x, y, z, 0, 0)
    
    if driver then
        self.driver = driver
        warpPedIntoVehicle(driver.element, self.element)
        
        local driveSpeed = speed or (40/180)
        driver:enableHLC("run", 1, driveSpeed)
        
        -- Route initialization is now handled by TrafficManager (Legacy System)
        -- if startNodeID and nextNodeID then
        --    driver:startRoute(startNodeID, nextNodeID, conn)
        -- end
        
        -- Spawnar passageiros aleatórios
        self:spawnPassengers(0.4)
        
        return driver
    end
end

function TrafficVehicle:spawnPassengers(passengerChance)
    local maxPass = getVehicleMaxPassengers(self.element)
    if not maxPass or maxPass <= 0 then return end
    
    -- Lista de skins
    local skins = {7, 9, 10, 11, 12, 13, 14, 15, 17, 20, 21, 22, 23, 24, 25, 26, 28, 29, 30, 32, 33, 34, 35, 36, 37, 40, 41, 43, 44, 46, 47, 48, 55, 56, 57, 58, 59, 60, 68, 69, 70, 72, 73, 76, 78, 79, 82, 83, 84, 91, 93, 120, 121, 122, 123}
    
    local x, y, z = getElementPosition(self.element)
    local dim = getElementDimension(self.element)
    local vehicle = self.element
    
    -- Seat 0 é o driver, começar em 1
    for seat = 1, math.min(maxPass, 3) do
        if math.random() < (passengerChance or 0.3) then
            local model = skins[math.random(#skins)]
            local ped = createPed(model, x, y, z)
            if ped then
                setElementDimension(ped, dim)
                setElementData(ped, "traffic:managed", true)
                table.insert(self.passengers, ped)
                
                -- Delay para garantir que veículo esteja pronto
                setTimer(function()
                    if isElement(ped) and isElement(vehicle) then
                        warpPedIntoVehicle(ped, vehicle, seat)
                    end
                end, 500, 1)
            end
        end
    end
end

function TrafficVehicle:attachTrailer(trailerModel)
    if not isElement(self.element) then return end
    
    -- Lógica de trailer
    -- local trailer = createVehicle(...)
    -- attachTrailerToVehicle(self.element, trailer)
    -- table.insert(self.trailers, trailer)
end

function TrafficVehicle:destroy()
    if isElement(self.element) then
        destroyElement(self.element)
    end
    
    -- Limpar trailers
    for _, trailer in pairs(self.trailers) do
        if isElement(trailer) then destroyElement(trailer) end
    end
    
    -- Passageiros são limpos automaticamente pelo GTA/MTA quando veículo some?
    -- Melhor garantir:
    for _, ped in pairs(self.passengers) do
        if isElement(ped) then destroyElement(ped) end
    end
end

return TrafficVehicle
