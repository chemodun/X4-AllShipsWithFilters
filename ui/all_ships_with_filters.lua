-- All Ships with Filters
-- Adds an "All Ships" tab to the Property Owned map-menu panel.
-- The tab shows three sections in order:
--   1. Fleets              (fleet leader ships, same as the vanilla Fleets tab)
--   2. Stations            (only stations that have assigned ships; when expanded
--                           shows only the subordinate ships, no module or
--                           construction rows)
--   3. Unassigned ships    (same as the vanilla Unassigned Ships tab)
--
-- At the top of the tab a cascading filter strip lets the player narrow the
-- visible ships by any combination of: Type (purpose), Size, Sector, Docked.
-- Each active filter slot reveals the next slot, up to a maximum equal to the
-- number of available filter categories.
--
-- Compatible with X4 8.00 and 9.00.

local ffi = require("ffi")
local C   = ffi.C

ffi.cdef[[
  typedef uint64_t UniverseID;

  typedef struct {
    int major;
    int minor;
  } GameVersion;

  typedef struct {
    const char* id;
    const char* name;
    const char* icon;
    const char* description;
    const char* category;
    const char* categoryname;
    bool infinite;
    uint32_t requiredSkill;
  } OrderDefinition;

  typedef struct {
    size_t queueidx;
    const char* state;
    const char* statename;
    const char* orderdef;
    size_t actualparams;
    bool enabled;
    bool isinfinite;
    bool issyncpointreached;
    bool istemporder;
  } Order;

  typedef struct {
    size_t queueidx;
    const char* state;
    const char* statename;
    const char* orderdef;
    size_t actualparams;
    bool enabled;
    bool isinfinite;
    bool issyncpointreached;
    bool istemporder;
    bool isoverride;
  } Order2;

  typedef struct {
    uint32_t id;
    const char* orderdef;
    const char* message;
    double timestamp;
    bool wasdefaultorder;
    bool wasinloop;
  } OrderFailure;

  GameVersion  GetGameVersion(void);
  UniverseID   GetPlayerID(void);
  bool         GetDefaultOrder(Order* result, UniverseID controllableid);
  bool         GetOrderDefinition(OrderDefinition* result, const char* orderdef);
  uint32_t     GetNumOrders(UniverseID controllableid);
  uint32_t     GetOrders2(Order2* result, uint32_t resultlen, UniverseID controllableid);
  size_t       GetOrderQueueCurrentIdx(UniverseID controllableid);
  void         GetOrderQueueFirstLoopIdx(UniverseID controllableid, bool* hasloop);
  bool         HasControllableAnyOrderFailures(UniverseID controllableid);
]]

-- *** constants ***

local PAGE_ID  = 1972092422
local MODE     = "allShipsWithFilters"
local TAB_ICON = "mapst_ol_ships"

-- Canonical size order (largest first for display).
local SIZE_ORDER = { "xl", "l", "m", "s", "xs" }

-- All filter dimension IDs in display order.
local ALL_DIMS = { "type", "size", "sector", "docked", "defaultorder", "order", "failedorder" }

-- *** module table ***

local asf = {
  menuMap       = nil,
  menuMapConfig = {},
  isV9          = C.GetGameVersion().major >= 9,
  playerId      = nil,

  -- Per-ship enrichment data, keyed by tostring(luaId).
  -- Populated by asf.enrichShipData (on_every_playerobject callback).
  shipData      = {},

  -- Filter state: array of { dim = "none"|"type"|"size"|"sector"|"docked",
  --                           value = nil|string }
  -- Always ends with exactly one trailing slot whose dim == "none".
  filterSlots   = { { dim = "none", value = nil } },
}

-- *** debug helpers ***

local debugLevel = "none"   -- "none" | "debug" | "trace"; updated by MD config

local function debug(msg)
  if debugLevel ~= "none" and type(DebugError) == "function" then
    DebugError("AllShipsWithFilters: " .. msg)
  end
end

local function trace(msg)
  if debugLevel == "trace" and type(DebugError) == "function" then
    DebugError("AllShipsWithFilters [trace]: " .. msg)
  end
end

-- *** helpers ***

local function getShipSize(classid)
  if not classid then return "s" end
  if Helper.isComponentClass(classid, "ship_xl") then return "xl"
  elseif Helper.isComponentClass(classid, "ship_l")  then return "l"
  elseif Helper.isComponentClass(classid, "ship_m")  then return "m"
  elseif Helper.isComponentClass(classid, "ship_xs") then return "xs"
  else return "s" end
end

local cachedSizeLabels = nil
local function sizeLabels()
  if not cachedSizeLabels then
    cachedSizeLabels = {
      xs = ReadText(1001, 52),
      s  = ReadText(1001, 51),
      m  = ReadText(1001, 50),
      l  = ReadText(1001, 49),
      xl = ReadText(1001, 48),
    }
  end
  return cachedSizeLabels
end

local cachedPurposeLabels = nil
local function purposeLabels()
  if not cachedPurposeLabels then
    cachedPurposeLabels = {
      fight     = ReadText(20213, 300),
      auxiliary = ReadText(20213, 1500),
      trade     = ReadText(20213, 200),
      mine      = ReadText(20213, 500),
      salvage   = ReadText(20213, 1800),
      build     = ReadText(20213, 400),
      neutral   = ReadText(1001, 3840),
    }
  end
  return cachedPurposeLabels
end

local function valueLabel(dim, value)
  if dim == "type" then
    return purposeLabels()[value] or value
  elseif dim == "size" then
    return sizeLabels()[value] or value
  elseif dim == "sector" then
    return value
  elseif dim == "docked" then
    if value == "1" then return ReadText(1001, 2617)
    else                 return ReadText(1001, 2618) end
  elseif dim == "defaultorder" or dim == "order" then
    -- value is the order-definition name string
    return value
  elseif dim == "failedorder" then
    if value == "1" then return ReadText(1001, 2617)  -- "Yes"
    else                 return ReadText(1001, 2618) end -- "No"
  end
  return value
end

local function dimLabel(dim)
  if dim == "type"         then return ReadText(1001, 6400)  end  -- "Type"
  if dim == "size"         then return ReadText(1001, 8026)  end  -- "Size"
  if dim == "sector"       then return ReadText(1001, 11284) end  -- "Sector"
  if dim == "docked"       then return ReadText(1001, 3249) end -- "Docked"
  if dim == "defaultorder" then return ReadText(1001, 8320)  end  -- "Default Behaviour"
  if dim == "order"        then return ReadText(1001, 8392)  end  -- "Current Order"
  if dim == "failedorder"  then return ReadText(1001, 11621) end  -- "Failed Orders"
  return dim
end

-- *** order helpers ***

-- Returns the human-readable name of a ship's current order (or default
-- order / nil for failed-order flag).  All three share the same FFI path.
local function getOrderNames(luaId)
  local comp64 = ConvertIDTo64Bit(luaId)

  -- Default order (behaviour).
  local defaultOrderName = nil
  local defBuf = ffi.new("Order")
  if C.GetDefaultOrder(defBuf, comp64) then
    local defId = (defBuf.orderdef ~= nil) and ffi.string(defBuf.orderdef) or ""
    if defId ~= "" then
      local defDef = ffi.new("OrderDefinition")
      if C.GetOrderDefinition(defDef, defId) then
        local n = (defDef.name ~= nil) and ffi.string(defDef.name) or ""
        if n ~= "" then defaultOrderName = n end
      end
    end
  end


  -- Current order (top of queue).
  local currentOrderName = nil
  local n = C.GetNumOrders(comp64)
  if n > 0 then
    local buf = ffi.new("Order2[?]", n)
    n = C.GetOrders2(buf, n, comp64)
    if n > 0 then
      local idx = tonumber(C.GetOrderQueueCurrentIdx(comp64)) - 1  -- convert to Lua 0-based index
      if idx >= 0 and idx < n then
        local orderDef = (buf[idx].orderdef ~= nil) and ffi.string(buf[idx].orderdef) or ""
        if orderDef ~= "" then
          local od = ffi.new("OrderDefinition")
          if C.GetOrderDefinition(od, orderDef) then
            local nm = (od.name ~= nil) and ffi.string(od.name) or ""
            if nm ~= "" then currentOrderName = nm end
          end
        end
      end
    end
  end


  -- Has any failed orders?
  local hasFailed = C.HasControllableAnyOrderFailures(comp64) and "1" or "0"

  return defaultOrderName, currentOrderName, hasFailed
end

-- *** enrichment ***

function asf.enrichShipData(infoTableData, entry, propertyMode)
  if propertyMode ~= MODE then return end
  if not Helper.isComponentClass(entry.classid, "ship") then return end

  local purpose = entry.purpose
  if not purpose or purpose == "" then purpose = "neutral" end

  local sectorName = entry.sector
  if not sectorName or sectorName == "" then sectorName = "?" end

  local isDocked = GetComponentData(entry.id, "isdocked")

  local defaultOrderName, currentOrderName, hasFailed = getOrderNames(entry.id)

  asf.shipData[tostring(entry.id)] = {
    purpose          = purpose,
    size             = getShipSize(entry.classid),
    sectorName       = sectorName,
    isDocked         = isDocked and "1" or "0",
    defaultOrderName = defaultOrderName,
    currentOrderName = currentOrderName,
    hasFailed        = hasFailed,
  }
end

-- *** filter logic ***

local function shipPassesFilter(luaId)
  local data = asf.shipData[tostring(luaId)]
  if data == nil then return true end

  for _, slot in ipairs(asf.filterSlots) do
    if slot.dim ~= "none" and slot.value ~= nil then
      local actual
      if     slot.dim == "type"         then actual = data.purpose
      elseif slot.dim == "size"         then actual = data.size
      elseif slot.dim == "sector"       then actual = data.sectorName
      elseif slot.dim == "docked"       then actual = data.isDocked
      elseif slot.dim == "defaultorder" then actual = data.defaultOrderName
      elseif slot.dim == "order"        then actual = data.currentOrderName
      elseif slot.dim == "failedorder"  then actual = data.hasFailed
      end
      if actual ~= slot.value then return false end
    end
  end
  return true
end

local function hasActiveFilter()
  for _, slot in ipairs(asf.filterSlots) do
    if slot.dim ~= "none" and slot.value ~= nil then return true end
  end
  return false
end

local function filterShips(ships)
  if not hasActiveFilter() then return ships end
  local result = {}
  for _, ship in ipairs(ships) do
    if shipPassesFilter(ship) then
      table.insert(result, ship)
    end
  end
  return result
end

local function allShipsUnfiltered(infoTableData)
  local all = {}
  for _, s in ipairs(infoTableData.fleetLeaderShips)  do table.insert(all, s) end
  for _, s in ipairs(infoTableData.unassignedShips)   do table.insert(all, s) end
  for _, stationId in ipairs(infoTableData.stations) do
    local subs = infoTableData.subordinates[tostring(stationId)] or {}
    for _, sub in ipairs(subs) do
      if sub.component then table.insert(all, sub.component) end
    end
  end
  return all
end

local function getValuesForDim(dim, allShips)
  local seen   = {}
  local result = {}
  local orderMap = nil
  if dim == "size" then
    orderMap = {}
    for i, s in ipairs(SIZE_ORDER) do orderMap[s] = i end
  end

  for _, luaId in ipairs(allShips) do
    local data = asf.shipData[tostring(luaId)]
    if data then
      local v
      if     dim == "type"         then v = data.purpose
      elseif dim == "size"         then v = data.size
      elseif dim == "sector"       then v = data.sectorName
      elseif dim == "docked"       then v = data.isDocked
      elseif dim == "defaultorder" then v = data.defaultOrderName
      elseif dim == "order"        then v = data.currentOrderName
      elseif dim == "failedorder"  then v = data.hasFailed
      end
      if v and not seen[v] then
        seen[v] = true
        table.insert(result, v)
      end
    end
  end

  if dim == "size" and orderMap then
    table.sort(result, function(a, b)
      return (orderMap[a] or 99) < (orderMap[b] or 99)
    end)
  elseif dim == "docked" or dim == "failedorder" then
    table.sort(result, function(a, b) return a > b end)  -- "1" (yes) before "0" (no)
  else
    table.sort(result)
  end

  return result
end

-- *** tab registration ***

function asf.setupTab()
  local cfg        = asf.menuMapConfig
  local categories = cfg and cfg.propertyCategories or nil
  if categories == nil then
    debug("propertyCategories not found in menuMapConfig")
    return
  end

  local insertBefore = nil   -- insert our tab at (insertBefore - 1) + 1 = insertBefore slot
  local insertAfter  = nil   -- fallback: insert after this index
  local fallbackIdx  = nil

  for i, cat in ipairs(categories) do
    if cat.category == MODE then
      debug("tab already registered")
      return
    end
    -- Place before fleets when fleets exists (highest priority).
    if cat.category == "fleets"          then insertBefore = i end
    -- Fallbacks if fleets not present.
    if cat.category == "unassignedships" and not insertBefore then insertAfter = i end
    if cat.category == "inventoryships"  and not insertBefore then insertAfter = i end
    if string.sub(cat.category, 1, 10) ~= "custom_tab" then
      fallbackIdx = i
    end
  end

  local idx
  if insertBefore then
    idx = insertBefore - 1   -- table.insert(categories, idx+1, …) will land at insertBefore
  else
    idx = insertAfter or fallbackIdx
  end

  if idx then
    table.insert(categories, idx + 1, {
      category = MODE,
      name     = ReadText(PAGE_ID, 1),
      icon     = TAB_ICON,
    })
  end
end

-- *** simplified station row ***

local function createStationRow(instance, tblOrGroup, ftable, stationId, numDisplayed, infoTableData)
  local menu   = asf.menuMap
  local key    = tostring(stationId)
  local comp64 = ConvertIDTo64Bit(stationId)

  if not menu.isPropertyExtended(key) then
    if menu.isCommander(comp64, 0) then
      menu.extendedproperty[key] = true
    end
  end

  numDisplayed = numDisplayed + 1

  local name, color, bgColor, font, mouseover =
      menu.getContainerNameAndColors(stationId, 0, true, false, true)
  local sectorId, locationText = GetComponentData(stationId, "sectorid", "sector")

  local displayText = Helper.convertColorToText(color) .. name .. "\027X"
      .. "\n" .. (locationText or "")

  local maxIcons = menu.infoTableData[instance].maxIcons

  local row = tblOrGroup:addRow({"property", stationId, nil, 0}, {
    bgColor       = bgColor,
    multiSelected = menu.isSelectedComponent(stationId),
  })
  if menu.isSelectedComponent(stationId) then
    menu.setrow = row.index
  end
  if IsSameComponent(stationId, menu.highlightedbordercomponent) then
    menu.sethighlightborderrow = row.index
  end

  row[1]:createButton({ scaling = false })
        :setText(menu.isPropertyExtended(key) and "-" or "+", { scaling = true, halign = "center" })
  row[1].handlers.onClick = function() return menu.buttonExtendProperty(key) end

  row[2]:setColSpan(4 + maxIcons):createText(displayText, { font = font, mouseOverText = mouseover })

  local rowHeight = row[2]:getMinTextHeight(true)
  if row[1].type == "button" then
    row[1].properties.height = rowHeight
  end

  if menu.isPropertyExtended(key) then
    -- Filter subordinates if a filter is active, so only matching ships are
    -- shown in the expanded list.
    local savedSubs = nil
    if hasActiveFilter() then
      local subs = infoTableData.subordinates[key]
      if subs then
        savedSubs = subs
        local filtered = {}
        for _, sub in ipairs(subs) do
          if sub.component and shipPassesFilter(sub.component) then
            table.insert(filtered, sub)
          end
        end
        infoTableData.subordinates[key] = filtered
      end
    end

    if asf.isV9 then
      numDisplayed = menu.createSubordinateSection(
        instance, ftable, tblOrGroup, stationId,
        false, true, 0, sectorId,
        numDisplayed, menu.propertySorterType, true, false)
    else
      numDisplayed = menu.createSubordinateSection(
        instance, ftable, stationId,
        false, true, 0, sectorId,
        numDisplayed, menu.propertySorterType, true, false)
    end

    -- Restore original subordinate list.
    if savedSubs ~= nil then
      infoTableData.subordinates[key] = savedSubs
    end
  end

  return numDisplayed
end

-- *** filter UI strip ***

local function renderFilterRows(ftable, instance, infoTableData)
  local cfg       = asf.menuMapConfig
  local rowHeight = cfg.mapRowHeight or 30
  local fontSize  = cfg.mapFontSize  or Helper.standardFontSize
  local maxIcons  = infoTableData.maxIcons
  local totalCols = 5 + maxIcons

  -- Normalise filterSlots: guard against empty array, trim extra trailing
  -- "none" slots, then ensure exactly one trailing "none" slot.
  if #asf.filterSlots == 0 then
    table.insert(asf.filterSlots, { dim = "none", value = nil })
  end
  while #asf.filterSlots > 1
      and asf.filterSlots[#asf.filterSlots].dim == "none" do
    table.remove(asf.filterSlots)
  end
  if asf.filterSlots[#asf.filterSlots].dim ~= "none" then
    if #asf.filterSlots < #ALL_DIMS then
      table.insert(asf.filterSlots, { dim = "none", value = nil })
    end
  end
  -- Hard cap.
  while #asf.filterSlots > #ALL_DIMS do
    table.remove(asf.filterSlots)
  end

  local allShips  = allShipsUnfiltered(infoTableData)
  local usedDims  = {}
  local slotCount = #asf.filterSlots

  -- Determine which content items are expandable (fleet leaders and stations
  -- that have subordinates) and whether all are currently expanded.
  local expandableKeys = {}
  local menuRef = asf.menuMap
  for _, leaderId in ipairs(infoTableData.fleetLeaderShips) do
    local key  = tostring(leaderId)
    local subs = infoTableData.subordinates[key]
    if subs and #subs > 0 then
      table.insert(expandableKeys, key)
    end
  end
  for _, stationId in ipairs(infoTableData.stations) do
    local key  = tostring(stationId)
    local subs = infoTableData.subordinates[key] or {}
    if subs.hasRendered then
      table.insert(expandableKeys, key)
    end
  end
  local hasExpandable = #expandableKeys > 0
  local allExpanded   = hasExpandable
  if hasExpandable then
    for _, key in ipairs(expandableKeys) do
      if not menuRef.isPropertyExtended(key) then
        allExpanded = false
        break
      end
    end
  end

  -- Header row: expand/collapse button (col 1) + "Filter by:" label (col 2), no other controls.
  local filterGroup = ftable
  if asf.isV9 then
    filterGroup = ftable:addRowGroup({})
  end

  local headerRow = filterGroup:addRow(hasExpandable and "asf_filter_header" or false, { fixed = true })
  if hasExpandable then
    local btn = headerRow[1]:createButton({ scaling = false })
    btn:setText(allExpanded and "-" or "+", { scaling = true, halign = "center" })
    headerRow[1].handlers.onClick = function()
      if allExpanded then
        for _, key in ipairs(expandableKeys) do
          menuRef.extendedproperty[key] = nil
        end
      else
        for _, key in ipairs(expandableKeys) do
          menuRef.extendedproperty[key] = true
        end
      end
      menuRef.refreshInfoFrame()
    end
  end
  headerRow[2]:createText(ReadText(PAGE_ID, 100), { halign = "left", fontsize = fontSize })

  for slotIdx = 1, slotCount do
    local slot = asf.filterSlots[slotIdx]

    -- Category dropdown options: "None" + all dims not yet used in earlier slots.
    local catOptions = {
      { id = "none", text = ReadText(1042, 10011), icon = "", displayremoveoption = false },
    }
    for _, d in ipairs(ALL_DIMS) do
      if not usedDims[d] then
        table.insert(catOptions, {
          id                  = d,
          text                = dimLabel(d),
          icon                = "",
          displayremoveoption = false,
        })
      end
    end

    -- Value dropdown options (built only when dim is active).
    -- First entry is always "None" so the player can pick a category
    -- without immediately filtering to a specific value.
    local valOptions = nil
    if slot.dim ~= "none" then
      valOptions = {
        { id = "__none__", text = ReadText(1042, 10011), icon = "", displayremoveoption = false },
      }
      for _, v in ipairs(getValuesForDim(slot.dim, allShips)) do
        table.insert(valOptions, {
          id                  = v,
          text                = valueLabel(slot.dim, v),
          icon                = "",
          displayremoveoption = false,
        })
      end
    end

    -- Filter row: col 1 empty, col 2 = category dropdown, col 3..totalCols-1 = value dropdown.
    local fRow = filterGroup:addRow("asf_filter_" .. slotIdx, { fixed = true })

    -- Col 2: category dropdown.
    local catDD = fRow[2]:createDropDown(
      catOptions,
      { startOption = slot.dim, active = true, height = rowHeight }
    )
    catDD:setTextProperties({ fontsize = fontSize })

    local capturedIdx = slotIdx
    fRow[2].handlers.onDropDownConfirmed = function(_, id)
      asf.menuMap.noupdate = false
      if id == "none" then
        -- Remove only this slot; leave all other slots intact.
        table.remove(asf.filterSlots, capturedIdx)
        if #asf.filterSlots == 0 then
          table.insert(asf.filterSlots, { dim = "none", value = nil })
        end
      else
        asf.filterSlots[capturedIdx].dim   = id
        asf.filterSlots[capturedIdx].value = nil
        -- Drop all slots after this one (their dims may have been invalidated).
        while #asf.filterSlots > capturedIdx do
          table.remove(asf.filterSlots)
        end
      end
      asf.menuMap.refreshInfoFrame()
    end
    fRow[2].handlers.onDropDownActivated = function()
      asf.menuMap.noupdate = true
    end

    -- Col 3 to totalCols-1: value dropdown (only when dim is active and values exist).
    -- When value is nil the "None" sentinel is shown, meaning no value filter.
    if slot.dim ~= "none" and valOptions and #valOptions > 0 then
      local valDD = fRow[3]:setColSpan(totalCols - 3):createDropDown(
        valOptions,
        { startOption = slot.value or "__none__", active = true, height = rowHeight }
      )
      valDD:setTextProperties({ fontsize = fontSize })

      local capturedIdx2 = slotIdx
      fRow[3].handlers.onDropDownConfirmed = function(_, id)
        asf.menuMap.noupdate = false
        if id == "__none__" then
          asf.filterSlots[capturedIdx2].value = nil
        else
          asf.filterSlots[capturedIdx2].value = id
        end
        asf.menuMap.refreshInfoFrame()
      end
      fRow[3].handlers.onDropDownActivated = function()
        asf.menuMap.noupdate = true
      end
    end

    -- Track used dims so later slots don't offer duplicates.
    if slot.dim ~= "none" then
      usedDims[slot.dim] = true
    end
  end

  -- 1 header row + one row per filter slot.
  return 1 + slotCount
end

-- *** display callback ***

function asf.displayTabData(numDisplayed, instance, ftable, infoTableData)
  if asf.menuMap.propertyMode ~= MODE then
    return { numdisplayed = numDisplayed }
  end

  local menu      = asf.menuMap
  local maxIcons  = infoTableData.maxIcons
  local totalCols = 5 + maxIcons
  local noneText  = "-- " .. ReadText(1001, 34) .. " --"

  -- ── Filter rows (fixed, at top) ──────────────────────────────────────────
  numDisplayed = numDisplayed + renderFilterRows(ftable, instance, infoTableData)

  -- ── Section 1: Fleets ────────────────────────────────────────────────────
  -- A fleet is shown when the commander passes the filter, or when at least
  -- one subordinate passes the filter (or both).
  -- Fleet unit group entries (no .component) are always passed through so
  -- the expand/collapse button is preserved.
  -- hasRendered controls the expand button; set it to reflect filtered count.
  local filteredFleets = {}
  local savedFleetSubs = {}
  if hasActiveFilter() then
    for _, leaderId in ipairs(infoTableData.fleetLeaderShips) do
      local key = tostring(leaderId)
      local subs = infoTableData.subordinates[key]
      local commanderPasses = shipPassesFilter(leaderId)
      local filtered = {}
      if subs then
        for _, sub in ipairs(subs) do
          if sub.fleetunit then
            table.insert(filtered, sub)
          elseif sub.component and shipPassesFilter(sub.component) then
            table.insert(filtered, sub)
          end
        end
      end
      -- Include this fleet if commander or any sub (with .component) passes.
      local subPasses = false
      for _, sub in ipairs(filtered) do
        if sub.component then subPasses = true; break end
      end
      if commanderPasses or subPasses then
        table.insert(filteredFleets, leaderId)
        if subs then
          savedFleetSubs[key] = subs
          filtered.hasRendered = #filtered > 0
          infoTableData.subordinates[key] = filtered
        end
      end
    end
  else
    filteredFleets = infoTableData.fleetLeaderShips
  end

  numDisplayed = menu.createPropertySection(
    instance, "asf_fleets", ftable,
    ReadText(1001, 8326),
    filteredFleets,
    noneText, nil, numDisplayed, nil, menu.propertySorterType)

  -- Restore fleet leader subordinate lists.
  for key, orig in pairs(savedFleetSubs) do
    infoTableData.subordinates[key] = orig
  end

  -- ── Section 2: Stations with assigned ships ───────────────────────────────
  local stationHeaderRow = ftable:addRow(false, { bgColor = Color["row_background_blue"] })
  stationHeaderRow[1]:setColSpan(totalCols)
                     :createText(ReadText(PAGE_ID, 110), Helper.headerRowCenteredProperties)

  local tblOrGroup = ftable
  if asf.isV9 then
    tblOrGroup = ftable:addRowGroup({})
  end

  local prevDisplayed = numDisplayed

  for _, stationId in ipairs(infoTableData.stations) do
    local key          = tostring(stationId)
    local subordinates = infoTableData.subordinates[key] or {}
    if subordinates.hasRendered then
      -- When a filter is active, only show the station if at least one sub passes.
      local stationVisible = true
      if hasActiveFilter() then
        stationVisible = false
        for _, sub in ipairs(subordinates) do
          if sub.component and shipPassesFilter(sub.component) then
            stationVisible = true
            break
          end
        end
      end
      if stationVisible then
        numDisplayed = createStationRow(instance, tblOrGroup, ftable, stationId, numDisplayed, infoTableData)
      end
    end
  end

  if numDisplayed == prevDisplayed then
    local emptyRow = tblOrGroup:addRow(false, { interactive = false })
    emptyRow[2]:setColSpan(4 + maxIcons):createText("-- " .. ReadText(1001, 33) .. " --")
  end

  -- ── Section 3: Unassigned ships ──────────────────────────────────────────
  local filteredUnassigned = filterShips(infoTableData.unassignedShips)
  numDisplayed = menu.createPropertySection(
    instance, "asf_unassigned", ftable,
    ReadText(1001, 8327),
    filteredUnassigned,
    noneText, nil, numDisplayed, nil, menu.propertySorterType)

  return { numdisplayed = numDisplayed }
end

-- *** init ***

local function Init()
  debug("initialising")

  local menuMap = Helper.getMenu("MapMenu")
  if menuMap == nil or type(menuMap.registerCallback) ~= "function" then
    debug("MapMenu not found — kuertee UI Extensions not loaded?")
    return
  end

  asf.menuMap       = menuMap
  asf.menuMapConfig = menuMap.uix_getConfig() or {}
  asf.playerId      = ConvertStringTo64Bit(tostring(C.GetPlayerID()))

  menuMap.registerCallback(
    "createPropertyOwned_on_every_playerobject",
    asf.enrichShipData)
  menuMap.registerCallback(
    "createPropertyOwned_on_createPropertySection_unassignedships",
    asf.displayTabData)

  -- Load debug level from MD config (if already set in this session).
  RegisterEvent("AllShipsWithFilters.ConfigChanged", function(_, param)
    if param and param.debugMode then
      debugLevel = param.debugMode
      debug("debug mode set to: " .. debugLevel)
    end
  end)

  asf.setupTab()
end

Register_OnLoad_Init(Init)