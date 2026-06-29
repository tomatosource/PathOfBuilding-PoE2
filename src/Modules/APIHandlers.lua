-- Path of Building API Handlers
-- Registered onto an APIServer instance.  All handlers receive (req, params)
-- and return a JSON-serialisable value (or APIServer.Respond(status, body)).

local json = require("dkjson")

local H = {}

-- Pending async trade searches: token → { status, url, error }
local pendingSearches = {}

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function getBuild()
	if not main then error("App not initialised") end
	if main.mode ~= "BUILD" or not main.modes or not main.modes["BUILD"] then
		error("No build loaded")
	end
	return main.modes["BUILD"]
end

-- Shallow-copy a table keeping only JSON-safe scalar values.
-- Skips functions, userdata, and tables (unless recurse=true, 1 level).
local function safeSerialise(t, recurse)
	local out = {}
	for k, v in pairs(t) do
		local kt = type(k)
		local vt = type(v)
		if (kt == "string" or kt == "number") then
			if vt == "number" or vt == "boolean" or vt == "string" then
				out[k] = v
			elseif vt == "table" and recurse then
				out[k] = safeSerialise(v, false)
			end
		end
	end
	return out
end

-- Serialise a single item to a compact table.
local function serialiseItem(item)
	if not item then return nil end
	local mods = {}
	for _, src in ipairs({ item.explicitModLines or {}, item.implicitModLines or {} }) do
		for _, line in ipairs(src) do
			if line.line and #line.line > 0 then
				table.insert(mods, line.line)
			end
		end
	end
	local armour = {}
	if item.armourData then
		for k, v in pairs(item.armourData) do armour[k] = v end
	end
	return {
		id        = item.id,
		name      = item.name,
		base      = item.baseName,
		rarity    = item.rarity,
		level     = item.itemLevel,
		quality   = item.quality,
		corrupted = item.corrupted,
		mods      = mods,
		armour    = armour,
		raw       = item.raw,
	}
end

-- ── Route registrar ───────────────────────────────────────────────────────────

function H.register(api)
	local R = api.Respond

	-- ── GET /api/status ────────────────────────────────────────────────────
	api:Route("GET", "/api/status", function(req, params)
		local build = getBuild()
		return {
			running   = true,
			buildName = build.buildName,
			class     = build.spec and build.spec.curClassName,
			ascendancy = build.spec and build.spec.curAscendClassName,
			level     = build.characterLevel,
			port      = 49185,
		}
	end)

	-- ── GET /api/stats ─────────────────────────────────────────────────────
	-- Returns all computed mainOutput values plus a curated summary.
	api:Route("GET", "/api/stats", function(req, params)
		local build = getBuild()
		if not build.calcsTab or not build.calcsTab.mainOutput then
			return R(503, {error = "Calc output not available"})
		end
		local out = build.calcsTab.mainOutput

		-- Curated summary of the most useful stats
		local summary = {
			-- Offence
			TotalDPS          = out.TotalDPS,
			CombinedDPS       = out.CombinedDPS,
			AverageDamage     = out.AverageDamage,
			Speed             = out.Speed,
			HitChance         = out.HitChance,
			CritChance        = out.CritChance,
			CritMultiplier    = out.CritMultiplier,
			-- Defence
			Life              = out.Life,
			LifeRegenRate     = out.LifeRegenRate,
			EnergyShield      = out.EnergyShield,
			EnergyShieldRegenRate = out.EnergyShieldRegenRate,
			Mana              = out.Mana,
			ManaRegenRate     = out.ManaRegenRate,
			Armour            = out.Armour,
			Evasion           = out.Evasion,
			SpellSuppressionChance = out.SpellSuppressionChance,
			-- Resistances
			FireResist        = out.FireResist,
			ColdResist        = out.ColdResist,
			LightningResist   = out.LightningResist,
			ChaosResist       = out.ChaosResist,
			-- Passives
			TotalStrength     = out.Str,
			TotalDexterity    = out.Dex,
			TotalIntelligence = out.Int,
		}

		-- Full dump (all scalar values)
		local all = safeSerialise(out, true)

		return {summary = summary, all = all}
	end)

	-- ── GET /api/items ─────────────────────────────────────────────────────
	api:Route("GET", "/api/items", function(req, params)
		local build = getBuild()
		local tab = build.itemsTab
		local result = {}

		for slotName, slot in pairs(tab.slots) do
			local itemId = tab.activeItemSet and tab.activeItemSet[slotName] and tab.activeItemSet[slotName].selItemId
			if itemId and itemId ~= 0 then
				local item = tab.items[itemId]
				result[slotName] = serialiseItem(item)
			else
				result[slotName] = nil
			end
		end

		return result
	end)

	-- ── POST /api/items ────────────────────────────────────────────────────
	-- Body: { "slot": "Helmet", "itemText": "Item Name\nRarity: Rare\n..." }
	api:Route("POST", "/api/items", function(req, params)
		local body = req.body
		if not body or not body.slot or not body.itemText then
			return R(400, {error = "Body must have {slot, itemText}"})
		end

		local build = getBuild()
		local tab   = build.itemsTab

		-- Validate slot exists
		if not tab.slots[body.slot] then
			local validSlots = {}
			for s in pairs(tab.slots) do table.insert(validSlots, s) end
			return R(400, {error = "Unknown slot. Valid slots: " .. table.concat(validSlots, ", ")})
		end

		-- Parse and add item
		local item = new("Item", body.itemText)
		if not item or not item.name then
			return R(400, {error = "Failed to parse item text"})
		end

		tab:AddItem(item, true)  -- true = noAutoEquip

		-- Use the slot control's SetSelItemId which correctly updates both
		-- the control's own selItemId and activeItemSet[slotName].selItemId
		if tab.slots[body.slot] then
			tab.slots[body.slot]:SetSelItemId(item.id)
		elseif build.itemsTab.activeItemSet and build.itemsTab.activeItemSet[body.slot] then
			build.itemsTab.activeItemSet[body.slot].selItemId = item.id
		end

		-- Recalculate
		build.calcsTab:BuildOutput()

		return {
			ok   = true,
			item = serialiseItem(item),
			slot = body.slot,
		}
	end)

	-- ── DELETE /api/items/:slot ────────────────────────────────────────────
	api:Route("DELETE", "/api/items/:slot", function(req, params)
		local build = getBuild()
		local tab   = build.itemsTab
		local slot  = params.slot

		if not tab.slots[slot] then
			return R(404, {error = "Slot not found: " .. slot})
		end

		if tab.slots[slot] then
			tab.slots[slot]:SetSelItemId(0)
		elseif build.itemsTab.activeItemSet and build.itemsTab.activeItemSet[slot] then
			build.itemsTab.activeItemSet[slot].selItemId = 0
		end

		build.calcsTab:BuildOutput()

		return {ok = true, slot = slot}
	end)

	-- ── GET /api/tree ──────────────────────────────────────────────────────
	api:Route("GET", "/api/tree", function(req, params)
		local build = getBuild()
		local spec  = build.spec
		local nodes = {}
		local count = 0

		for id, node in pairs(spec.allocNodes) do
			count = count + 1
			table.insert(nodes, {
				id     = id,
				name   = node.name,
				type   = node.type,
				stats  = node.sd,
			})
		end

		-- Passive point totals
		local used, ascUsed = spec:CountAllocNodes()

		return {
			count          = count,
			pointsUsed     = used,
			ascPointsUsed  = ascUsed,
			nodes          = nodes,
		}
	end)

	-- ── POST /api/tree/:nodeId ─────────────────────────────────────────────
	api:Route("POST", "/api/tree/:nodeId", function(req, params)
		local build  = getBuild()
		local spec   = build.spec
		local nodeId = tonumber(params.nodeId)
		if not nodeId then return R(400, {error = "nodeId must be numeric"}) end

		local node = spec.tree.nodes[nodeId]
		if not node then return R(404, {error = "Node not found: " .. nodeId}) end

		if not spec.allocNodes[nodeId] then
			spec:AllocNode(node)
			build.calcsTab:BuildOutput()
		end

		return {ok = true, nodeId = nodeId, name = node.name, alreadyAllocated = spec.allocNodes[nodeId] ~= nil}
	end)

	-- ── DELETE /api/tree/:nodeId ───────────────────────────────────────────
	api:Route("DELETE", "/api/tree/:nodeId", function(req, params)
		local build  = getBuild()
		local spec   = build.spec
		local nodeId = tonumber(params.nodeId)
		if not nodeId then return R(400, {error = "nodeId must be numeric"}) end

		local node = spec.tree.nodes[nodeId]
		if not node then return R(404, {error = "Node not found: " .. nodeId}) end

		if spec.allocNodes[nodeId] then
			spec:DeallocNode(node)
			build.calcsTab:BuildOutput()
		end

		return {ok = true, nodeId = nodeId, name = node.name}
	end)

	-- ── GET /api/skills ────────────────────────────────────────────────────
	api:Route("GET", "/api/skills", function(req, params)
		local build = getBuild()
		local groups = {}

		for i, sg in ipairs(build.skillsTab.socketGroupList or {}) do
			local gems = {}
			for _, gem in ipairs(sg.gemList or {}) do
				table.insert(gems, {
					name    = gem.nameSpec,
					enabled = gem.enabled,
					level   = gem.level,
					quality = gem.quality,
				})
			end
			table.insert(groups, {
				index   = i,
				label   = sg.displayLabel,
				enabled = sg.enabled,
				slot    = sg.slot,
				gems    = gems,
			})
		end

		local mainSkill = build.calcsTab.mainEnv and
		                  build.calcsTab.mainEnv.player and
		                  build.calcsTab.mainEnv.player.mainSkill

		return {
			socketGroups = groups,
			mainSkillName = mainSkill and mainSkill.activeEffect and
			                mainSkill.activeEffect.grantedEffect and
			                mainSkill.activeEffect.grantedEffect.name,
		}
	end)

	-- ── POST /api/recalc ───────────────────────────────────────────────────
	-- Force a full recalculation and return fresh stats inline.
	api:Route("POST", "/api/recalc", function(req, params)
		local build = getBuild()
		build.calcsTab:BuildOutput()

		local out = build.calcsTab.mainOutput
		return {
			ok      = true,
			summary = {
				TotalDPS    = out.TotalDPS,
				CombinedDPS = out.CombinedDPS,
				Life        = out.Life,
				EnergyShield = out.EnergyShield,
				Mana        = out.Mana,
				Armour      = out.Armour,
				Evasion     = out.Evasion,
				FireResist  = out.FireResist,
				ColdResist  = out.ColdResist,
				LightningResist = out.LightningResist,
				ChaosResist = out.ChaosResist,
			},
		}
	end)

	-- ── POST /api/build/save ───────────────────────────────────────────────
	-- Returns the current build as an XML string.
	api:Route("POST", "/api/build/save", function(req, params)
		local build = getBuild()
		local xml   = build:SaveBuild()
		local xmlStr
		if type(xml) == "string" then
			xmlStr = xml
		else
			-- SaveBuild might return a table; serialise it
			local ok, s = pcall(function()
				return require("xml").SaveXML(xml)
			end)
			xmlStr = ok and s or "<?xml?>"
		end
		return {ok = true, buildName = build.buildName, xml = xmlStr}
	end)

	-- ── POST /api/build/load ───────────────────────────────────────────────
	-- Body: { "xml": "<?xml..." }  OR  { "path": "/abs/path/to/build.xml" }
	api:Route("POST", "/api/build/load", function(req, params)
		local body = req.body
		if not body then return R(400, {error = "JSON body required"}) end

		local build = getBuild()
		if body.path then
			build:LoadBuild(body.path)
		elseif body.xml then
			-- Write to a temp file then load — PoB's LoadBuild expects a path
			local tmp = os.tmpname() .. ".xml"
			local f   = assert(io.open(tmp, "w"))
			f:write(body.xml)
			f:close()
			build:LoadBuild(tmp)
			os.remove(tmp)
		else
			return R(400, {error = "Provide {xml} or {path}"})
		end

		return {ok = true, buildName = build.buildName}
	end)

	-- ── GET /api/nodes/search ──────────────────────────────────────────────
	-- Query param: q=fireDamage  → search node names/stats
	api:Route("GET", "/api/nodes/search", function(req, params)
		local build = getBuild()
		local q     = (req.query.q or ""):lower()
		if #q < 2 then return R(400, {error = "Query too short (min 2 chars)"}) end

		local results = {}
		for id, node in pairs(build.spec.tree.nodes) do
			local nameMatch = node.name and node.name:lower():find(q, 1, true)
			local statMatch = false
			if not nameMatch and node.sd then
				for _, s in ipairs(node.sd) do
					if s:lower():find(q, 1, true) then statMatch = true; break end
				end
			end
			if nameMatch or statMatch then
				table.insert(results, {
					id       = id,
					name     = node.name,
					type     = node.type,
					allocated = build.spec.allocNodes[id] ~= nil,
					stats    = node.sd,
				})
				if #results >= 50 then break end
			end
		end

		table.sort(results, function(a, b) return a.name < b.name end)
		return {count = #results, nodes = results}
	end)

	-- ── POST /api/trade/url ────────────────────────────────────────────────
	-- Submits a search to the PoE2 trade API using the existing tradeQueryRequests
	-- infrastructure (handles auth, rate limiting, etc).
	-- Body: {
	--   category: "accessory.ring" | "accessory.amulet" | ...
	--   filters: [ {id: "explicit.stat_XXX", min: N, max: N}, ... ]
	-- }
	-- Returns: { status: "pending", token: "...", poll: "/api/trade/url/TOKEN" }
	api:Route("POST", "/api/trade/url", function(req, params)
		local body = req.body
		if not body or not body.filters then
			return R(400, {error = "Body must have {category, filters:[{id,min?,max?}]}"})
		end

		-- Build stat filters
		local statFilters = {}
		for _, f in ipairs(body.filters) do
			local entry = {id = f.id, disabled = false, value = {}}
			if f.min then entry.value.min = f.min end
			if f.max then entry.value.max = f.max end
			table.insert(statFilters, entry)
		end

		-- Construct the query table
		local queryTable = {
			query = {
				status = {option = "online"},
				stats  = {{type = "and", filters = statFilters}},
				filters = {
					type_filters = {
						filters = {
							category = {option = body.category or "accessory.amulet"},
						}
					}
				}
			},
			sort = {price = "asc"},
		}
		local queryJson = json.encode(queryTable)

		-- Get the trade infrastructure from the live build
		local build    = getBuild()
		local requests = build.itemsTab.tradeQuery.tradeQueryRequests

		-- Derive realm + league from main settings
		local realm  = "poe2"
		local league = "Standard"
		if main.modes and main.modes["LIST"] and main.modes["LIST"].lastLeague then
			league = main.modes["LIST"].lastLeague
		end

		-- Issue a unique token for the caller to poll on
		local token = tostring(os.clock()):gsub("[^%d]", "") .. tostring(math.random(1e6))
		pendingSearches[token] = {status = "pending"}

		-- Fire the async search — response arrives via ProcessQueue on a future frame
		requests:PerformSearch(realm, league, queryJson, function(response, errMsg)
			if errMsg then
				pendingSearches[token] = {status = "error", error = errMsg}
			elseif response and response.id then
				local url = requests:buildUrl(
					"https://www.pathofexile.com/trade2/search",
					realm, league, response.id)
				pendingSearches[token] = {status = "ready", url = url, queryId = response.id}
			else
				pendingSearches[token] = {status = "error", error = "No query ID returned"}
			end
		end)

		return {
			status  = "pending",
			token   = token,
			poll    = "/api/trade/url/" .. token,
			realm   = realm,
			league  = league,
		}
	end)

	-- ── GET /api/trade/url/:token ──────────────────────────────────────────
	-- Poll this until status = "ready", then read the url field.
	api:Route("GET", "/api/trade/url/:token", function(req, params)
		local result = pendingSearches[params.token]
		if not result then return R(404, {error = "Unknown token"}) end
		return result
	end)
end

return H
