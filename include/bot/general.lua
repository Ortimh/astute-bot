local method = {}

function method:reset()
	self._init = true
	self._mode = 0
	
	-- for movement
	self._velocity = vector()
	self._steering = vector() -- every frame is resetted
	
	-- for path-following movement
	self._path = nil
	self._curnode = 1 -- as index
	
	self._hiding = false
	self._tocover = false
	self._covering = false
	self._tocamp = false
	self._camping = false
	
	self._scannedspots = {}
	self._closespots = nil
	self._scanspot = nil
	self._hidingspot = nil
	self._tohidingspot = nil
	
	self._noise = false
	self._noise_x, self._noise_y = 0, 0
	self._noise_volume, self._noise_maxvolume = 0, 0
	
	self._prevx, self._prevy = 0, 0
	
	self._randomaimtime = 0
	self._reaimtime = 0
	self._target = 0
	
	self._buy = false
	self._buy_sub = 0
	self._buy_time = 0
	
	self._behavior = 'general' do
		local behavior
		
		if game 'sv_gamemode' == '0' then
			if map 'mission_bombspots' > 0 then
				behavior = 'bombdefuse'
			elseif map 'mission_vips' > 0 then
				behavior = 'assasination'
			elseif map 'mission_hostages' > 0 then
				behavior = 'hostagerescue'
			end
		end
		
		if map 'mission_ctfflags' > 0 then
			behavior = 'capturetheflag'
		elseif map 'mission_dompoints' > 0 then
			behavior = 'domination'
		end
		
		self._behavior = behavior or self._behavior
		local method = BOT_BEHAVIOR[self._behavior]
		-- Only takes 'decide' and 'behavior' methods
		self.decide = method.decide or error 'where is \'decide\' method?'
		self.behavior = method.behavior or error 'where is \'behavior\' method?'
	end
end

function method:isinrange(x, y)
	-- 393 = screen width (850) / 2 - player size (32); 208 = screen height (480) / 2 - player size (32)
	return math.abs(player(self._id, 'x') - x) < 393 and math.abs(player(self._id, 'y') - y) < 208
end

function method:isonsight(x, y)
	return BOT_SV_FOW == 0 or
		(math.abs(helper_angledelta(player(self._id, 'rot'),
									-- 65 = human's field of vision (130) / 2
									helper_angleto(player(self._id, 'x'), player(self._id, 'y'), x, y))) < 65 and ai_freeline(self._id, x, y))
end

do
	-- 'Bomb', 'Planted bomb', 'Red Flag', and 'Blue Flag' are exceptions to item scanner
	local exception = {[55] = true, [63] = true, [70] = true, [71] = true}
	
	-- Item scanner relies on the pricing of the items and the absency of the item
	-- TODO: Ammo needs to be taken into account
	-- FIXME: Scanning items feels heavy, don't you think so?
	function method:scanitems()
		local plitems = {}
		local slots = {}
		
		do
			local items = playerweapons(self._id)
			
			for i = 1, #items do
				local type = items[i]
				local slot = itemtype(type, 'slot')
				slots[slot] = slots[slot] or {}
				slots[slot][#slots[slot] + 1] = type
				plitems[type] = true
			end
		end
		
		local bot_x, bot_y = player(self._id, 'tilex'), player(self._id, 'tiley')
		-- 7 = floor((screen height (480) / 2) / 32)
		local items = closeitems(self._id, 7)
		
		for i = 1, #items do
			local iid = items[i]
			local x, y = item(iid, 'x'), item(iid, 'y')
			
			if not (bot_x == x and bot_y == y) then
				local type = item(iid, 'type')
				
				if not exception[type] and not plitems[type] then
					local price = itemtype(type, 'price')
					local slot = itemtype(type, 'slot')
					local tocollect
					
					if slot > 0 then
						if slots[slot] then
							local slots = slots[slot]
							local lowesttype, lowestprice
							
							for i = 1, #slots do
								local iprice = itemtype(slots[i], 'price')
								
								if iprice < price and (not lowestprice or price < lowestprice) then
									lowestprice = iprice
									lowesttype = slots[i]
								end
							end
							
							if lowestprice then
								tocollect = iid
								
								if helper_dist(bot_x, bot_y, x, y) <= 2 then
									ai_selectweapon(self._id, lowesttype)
									ai_drop(self._id)
								end
							end
						else
							tocollect = iid
						end
					else
						if type >= 66 and type <= 68 and player(self._id, 'money') < 16000 then
							tocollect = iid
						elseif type >= 64 and type <= 65 and player(self._id, 'health') < player(self._id, 'maxhealth') then
							tocollect = iid
						end
					end
					
					if tocollect then
						self:goto(x, y)
						
						break
					end
				end
			end
		end
	end
end

function method:goto(x, y)
	self._path = bot_path_get(player(self._id, 'tilex'), player(self._id, 'tiley'), x, y)
	self._curnode = 1
	self._mode = self._path ~= nil and -2 or 0
end

local debugmsg = 'm:%d t:%d a:%d n:%d|%.2f|%d,%d h:%d ca:%d|%d co:%d|%d'

function method:update()
	self:look()
	
	if self._target > 0 then
		self._mode = -3
	end
	
	if self._mode == 0 then
		if not self._buy then
			self._mode = -1 return
		end
		
		self:decide()
	elseif self._mode == -1 then
		self:buy()
	elseif self._mode == -2 then
		if self:pathfollowing() == 1 then
			self._mode = 0
		end
	elseif self._mode == -3 then
		self:engage()
	else
		self:behavior()
	end
	
	self:collisionavoidance()
	self:move()
	self:markscannedspots()
	self:diminishnoise()
	
	if BOT_DEBUGAI == 1 then
		local deg = math.deg(self._velocity:angleTo())
		deg = deg + 90 if deg > -180 and deg < 0 then deg = deg + 360 end
		
		ai_debug(self._id, debugmsg:format(
			self._mode,
			self._target,
			deg,
			self._noise and 1 or 0,
			self._noise and self._noise_volume or 0,
			self._noise and math.floor(self._noise_x / 32) or 0,
			self._noise and math.floor(self._noise_y / 32) or 0,
			self._hiding and 1 or 0,
			self._camping and 1 or 0,
			self._tocamp and 1 or 0,
			self._covering and 1 or 0,
			self._tocover and 1 or 0
		))
	end
end

return method