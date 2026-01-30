UPDATE_COUNT = 16
UPDATE_INTERVAL_MS = 5

-- Global NPC cache to avoid getElementsByType every frame
-- This reduces CPU cost from O(N) to O(1) in main loop
local streamed_npcs = {}

function initNPCControl()
	addEventHandler("onClientPreRender",root,cycleNPCs)
	
	-- Events to keep cache updated automatically
	addEventHandler("onClientElementStreamIn",root,cacheNPC)
	addEventHandler("onClientElementStreamOut",root,uncacheNPC)
	addEventHandler("onClientElementDestroy",root,uncacheNPC)
	
	-- Populate initial cache (once only)
	for i,ped in ipairs(getElementsByType("ped",root,true)) do
		if getElementData(ped,"npc_hlc") then
			streamed_npcs[ped] = true
		end
	end
end

function cacheNPC()
	if getElementType(source) == "ped" and getElementData(source,"npc_hlc") then
		streamed_npcs[source] = true
		
		-- ANTI-WARP: Hide "pop-in" teleport
		-- Start invisible
		setElementAlpha(source, 0)
		local vehicle = getPedOccupiedVehicle(source)
		if vehicle then setElementAlpha(vehicle, 0) end
		
		-- Fade in smoothly over 1.5 second
		local progress = 0
		setTimer(function(ped, veh)
			progress = progress + 0.1
			local alpha = math.min(255, progress * 255)
			
			if isElement(ped) then setElementAlpha(ped, alpha) end
			if isElement(veh) then setElementAlpha(veh, alpha) end
		end, 150, 10, source, vehicle)
	end
end

function uncacheNPC()
	if streamed_npcs[source] then
		streamed_npcs[source] = nil
	end
end

function cycleNPCs()
	-- Iterates only over cached list (much faster)
	for npc,_ in pairs(streamed_npcs) do
		-- Extra safety check
		if not isElement(npc) then
			streamed_npcs[npc] = nil
		elseif getElementHealth(getPedOccupiedVehicle(npc) or npc) >= 1 then
			while true do
				local thistask = getElementData(npc,"npc_hlc:thistask")
				if thistask then
					local task = getElementData(npc,"npc_hlc:task."..thistask)
					if task then
						if performTask[task[1]](npc,task) then
							setNPCTaskToNext(npc)
						else
							break
						end
					else
						stopAllNPCActions(npc)
						break
					end
				else
					stopAllNPCActions(npc)
					break
				end
			end
		else
			stopAllNPCActions(npc)
		end
	end
end

function setNPCTaskToNext(npc)
	setElementData(
		npc,"npc_hlc:thistask",
		getElementData(npc,"npc_hlc:thistask")+1,
		true
	)
end
