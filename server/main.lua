local config = require 'config.shared'

-- ============================================================================
-- yk_restaurant — server
-- All money movement, hiring, stock, crafting validation and payroll are
-- server-authoritative. Point actions are distance-checked against the player ped.
-- ============================================================================

local BUSINESS = config.business
local pendingOrders = {} -- [business] = { items, total, employee_cid, employee_name, register }

-- ---------------------------------------------------------------- helpers
local function getPlayer(src) return exports.qbx_core:GetPlayer(src) end
local function trim(s) return (tostring(s or ''):gsub('^%s+', ''):gsub('%s+$', '')) end

-- Bound / sanitize untrusted client input. Server callbacks are directly reachable by
-- modified clients, so every numeric/string field coming from the NUI is clamped here.
local function clampInt(v, lo, hi)
    v = tonumber(v)
    if not v or v ~= v then return lo end -- nil / NaN
    v = math.floor(v)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end
local function clampStr(s, max)
    s = trim(s)
    if #s > max then s = s:sub(1, max) end
    return s
end

-- Hard caps for input bounds (generous; only reject abusive values).
local LIMITS = {
    orderQty = 10000,     -- units per ingredient line in a wholesale order
    saleQty = 1000,       -- units per item in a single register order
    recipeQty = 1000,     -- units of an ingredient in one recipe
    recipeItems = 24,     -- distinct ingredients per recipe
    cartLines = 64,       -- distinct lines accepted from one cart payload
    price = 100000000,    -- max menu item price
    money = 1000000000,   -- max deposit/withdraw amount
    label = 60,           -- menu item name length
    icon = 512,           -- icon URL length
}

local function isCrew(player)
    return player and player.PlayerData.job and player.PlayerData.job.name == config.job
end

local function gradeLevel(player)
    local g = player and player.PlayerData.job and player.PlayerData.job.grade
    return (g and g.level) or 0
end

local function isManager(player) return isCrew(player) and gradeLevel(player) >= config.managementGrade end
local function isOwner(player) return isCrew(player) and gradeLevel(player) >= config.ownerGrade end
local function onDuty(player) return isCrew(player) and player.PlayerData.job.onduty end

local function fullName(ci)
    return trim(('%s %s'):format(ci and ci.firstname or '', ci and ci.lastname or ''))
end
local function playerName(player)
    local n = fullName(player.PlayerData.charinfo)
    return n ~= '' and n or 'Unknown'
end

-- Distance guard: player must be near a configured point.
local function nearPoint(src, point)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return false end
    local coords = GetEntityCoords(ped)
    local p = config.locations[point]
    if not p then return false end
    return #(coords - vector3(p.x, p.y, p.z)) <= config.interactDistance
end

-- ---------------------------------------------------------------- database
local function createTables()
    MySQL.query.await([[CREATE TABLE IF NOT EXISTS `yk_restaurant_business` (
        `id` VARCHAR(64) NOT NULL, `balance` INT NOT NULL DEFAULT 0,
        `payroll_pct` INT NOT NULL DEFAULT 10, PRIMARY KEY (`id`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;]])

    MySQL.query.await([[CREATE TABLE IF NOT EXISTS `yk_restaurant_menu` (
        `id` INT NOT NULL AUTO_INCREMENT, `business` VARCHAR(64) NOT NULL,
        `category` VARCHAR(16) NOT NULL, `label` VARCHAR(120) NOT NULL,
        `price` INT NOT NULL DEFAULT 0, `icon` VARCHAR(512) DEFAULT NULL,
        `ingredients` LONGTEXT NOT NULL, `active` TINYINT NOT NULL DEFAULT 1,
        PRIMARY KEY (`id`), KEY `business` (`business`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;]])

    MySQL.query.await([[CREATE TABLE IF NOT EXISTS `yk_restaurant_sales` (
        `id` INT NOT NULL AUTO_INCREMENT, `business` VARCHAR(64) NOT NULL,
        `employee_cid` VARCHAR(50) NOT NULL, `employee_name` VARCHAR(120) NOT NULL,
        `items` LONGTEXT NOT NULL, `total` INT NOT NULL DEFAULT 0,
        `method` VARCHAR(8) NOT NULL DEFAULT 'cash',
        `created_at` TIMESTAMP NOT NULL DEFAULT current_timestamp(),
        PRIMARY KEY (`id`), KEY `business` (`business`), KEY `employee_cid` (`employee_cid`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;]])

    MySQL.query.await([[CREATE TABLE IF NOT EXISTS `yk_restaurant_expenses` (
        `id` INT NOT NULL AUTO_INCREMENT, `business` VARCHAR(64) NOT NULL,
        `kind` VARCHAR(24) NOT NULL, `amount` INT NOT NULL DEFAULT 0, `detail` TEXT,
        `created_at` TIMESTAMP NOT NULL DEFAULT current_timestamp(),
        PRIMARY KEY (`id`), KEY `business` (`business`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;]])

    MySQL.query.await([[CREATE TABLE IF NOT EXISTS `yk_restaurant_payroll` (
        `business` VARCHAR(64) NOT NULL, `citizenid` VARCHAR(50) NOT NULL,
        `name` VARCHAR(120) NOT NULL, `accrued` INT NOT NULL DEFAULT 0,
        PRIMARY KEY (`business`, `citizenid`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;]])
end

local function seedDefaults()
    local exists = MySQL.scalar.await('SELECT 1 FROM yk_restaurant_business WHERE id = ?', { BUSINESS })
    if not exists then
        MySQL.insert.await('INSERT INTO yk_restaurant_business (id, balance, payroll_pct) VALUES (?,?,?)',
            { BUSINESS, config.startingBalance, config.defaultPayrollPct })
    end
    local menuCount = MySQL.scalar.await('SELECT COUNT(*) FROM yk_restaurant_menu WHERE business = ?', { BUSINESS })
    if (menuCount or 0) == 0 then
        for _, m in ipairs(config.defaultMenu) do
            MySQL.insert.await(
                'INSERT INTO yk_restaurant_menu (business, category, label, price, icon, ingredients, active) VALUES (?,?,?,?,?,?,1)',
                { BUSINESS, m.category, m.label, m.price, m.icon, json.encode(m.ingredients) })
        end
    end
end

-- ---------------------------------------------------------------- business account
local function getBalance()
    return MySQL.scalar.await('SELECT balance FROM yk_restaurant_business WHERE id = ?', { BUSINESS }) or 0
end
local function getPayrollPct()
    return MySQL.scalar.await('SELECT payroll_pct FROM yk_restaurant_business WHERE id = ?', { BUSINESS }) or config.defaultPayrollPct
end
local function addBalance(amount)
    MySQL.update.await('UPDATE yk_restaurant_business SET balance = balance + ? WHERE id = ?', { amount, BUSINESS })
end
local function logExpense(kind, amount, detail)
    MySQL.insert('INSERT INTO yk_restaurant_expenses (business, kind, amount, detail) VALUES (?,?,?,?)',
        { BUSINESS, kind, amount, detail })
end

-- ---------------------------------------------------------------- menu
local function loadMenu(activeOnly)
    local sql = 'SELECT id, category, label, price, icon, ingredients, active FROM yk_restaurant_menu WHERE business = ?'
    if activeOnly then sql = sql .. ' AND active = 1' end
    sql = sql .. ' ORDER BY category, label'
    local rows = MySQL.query.await(sql, { BUSINESS }) or {}
    for _, r in ipairs(rows) do
        local ok, decoded = pcall(json.decode, r.ingredients or '[]')
        r.ingredients = (ok and type(decoded) == 'table') and decoded or {}
        r.active = r.active == 1
    end
    return rows
end

local function getMenuItem(id)
    local r = MySQL.single.await('SELECT id, category, label, price, icon, ingredients FROM yk_restaurant_menu WHERE id = ? AND business = ?',
        { id, BUSINESS })
    if not r then return nil end
    local ok, decoded = pcall(json.decode, r.ingredients or '[]')
    r.ingredients = (ok and type(decoded) == 'table') and decoded or {}
    return r
end

-- ---------------------------------------------------------------- personnel
local function loadPersonnel()
    -- Join the canonical player_groups roster to the players table for names/grades.
    local rows = MySQL.query.await([[
        SELECT pg.citizenid AS citizenid, pg.grade AS grade, p.charinfo AS charinfo
        FROM player_groups pg
        LEFT JOIN players p ON p.citizenid = pg.citizenid
        WHERE pg.`group` = ? AND pg.`type` = 'job'
        ORDER BY pg.grade DESC]], { config.job }) or {}
    local out = {}
    for _, r in ipairs(rows) do
        local ci
        local ok, decoded = pcall(json.decode, r.charinfo or '{}')
        if ok then ci = decoded end
        out[#out + 1] = {
            citizenid = r.citizenid,
            grade = r.grade,
            name = fullName(ci) ~= '' and fullName(ci) or 'Unknown',
            online = exports.qbx_core:GetPlayerByCitizenId(r.citizenid) ~= nil,
        }
    end
    return out
end

local function gradeName(level)
    for name, lvl in pairs(config.grades) do
        if lvl == level then return name end
    end
    return tostring(level)
end

-- ---------------------------------------------------------------- analytics
local function buildAnalytics()
    local revenueAll = MySQL.scalar.await('SELECT COALESCE(SUM(total),0) FROM yk_restaurant_sales WHERE business = ?', { BUSINESS }) or 0
    local revenueDay = MySQL.scalar.await('SELECT COALESCE(SUM(total),0) FROM yk_restaurant_sales WHERE business = ? AND created_at >= (NOW() - INTERVAL 1 DAY)', { BUSINESS }) or 0
    local salesCount = MySQL.scalar.await('SELECT COUNT(*) FROM yk_restaurant_sales WHERE business = ?', { BUSINESS }) or 0
    local expenses = MySQL.scalar.await('SELECT COALESCE(SUM(amount),0) FROM yk_restaurant_expenses WHERE business = ?', { BUSINESS }) or 0

    local perEmployee = MySQL.query.await([[
        SELECT employee_name AS name, COUNT(*) AS orders, COALESCE(SUM(total),0) AS revenue
        FROM yk_restaurant_sales WHERE business = ?
        GROUP BY employee_cid, employee_name ORDER BY revenue DESC LIMIT 15]], { BUSINESS }) or {}

    -- Top selling items: items are stored as a JSON array per sale, so aggregate in Lua
    -- over a recent window to keep it cheap.
    local recent = MySQL.query.await('SELECT items FROM yk_restaurant_sales WHERE business = ? ORDER BY id DESC LIMIT 500', { BUSINESS }) or {}
    local tally = {}
    for _, row in ipairs(recent) do
        local ok, items = pcall(json.decode, row.items or '[]')
        if ok and type(items) == 'table' then
            for _, it in ipairs(items) do
                local key = it.label or 'Item'
                local t = tally[key] or { label = key, qty = 0, revenue = 0 }
                t.qty = t.qty + (it.qty or 1)
                t.revenue = t.revenue + ((it.price or 0) * (it.qty or 1))
                tally[key] = t
            end
        end
    end
    local topItems = {}
    for _, t in pairs(tally) do topItems[#topItems + 1] = t end
    table.sort(topItems, function(a, b) return a.qty > b.qty end)
    while #topItems > 8 do topItems[#topItems] = nil end

    return {
        revenueAll = revenueAll,
        revenueDay = revenueDay,
        salesCount = salesCount,
        expenses = expenses,
        profit = revenueAll - expenses,
        perEmployee = perEmployee,
        topItems = topItems,
    }
end

-- ---------------------------------------------------------------- stash stock
local function readStock()
    local items = exports.ox_inventory:GetInventoryItems(config.stash.id) or {}
    local known = {}
    for _, list in pairs(config.ingredients) do
        for _, ing in ipairs(list) do known[ing.item] = ing.label end
    end
    local counts = {}
    for _, item in pairs(items) do
        if item and item.name then
            counts[item.name] = (counts[item.name] or 0) + item.count
        end
    end
    local out = {}
    for itemName, label in pairs(known) do
        out[#out + 1] = { item = itemName, label = label, count = counts[itemName] or 0 }
    end
    table.sort(out, function(a, b) return a.label < b.label end)
    return out
end

CreateThread(function()
    createTables()
    seedDefaults()

    exports.ox_inventory:RegisterStash(
        config.stash.id, config.stash.label, config.stash.slots, config.stash.weight,
        nil, { [config.job] = 0 }, vector3(config.locations.stash.x, config.locations.stash.y, config.locations.stash.z))
end)

-- ============================================================================
-- Management menu
-- ============================================================================
lib.callback.register('yk_restaurant:server:openManagement', function(source)
    local player = getPlayer(source)
    if not isManager(player) then return { ok = false } end
    if not nearPoint(source, 'management') then return { ok = false } end
    return {
        ok = true,
        role = isOwner(player) and 'owner' or 'manager',
        grades = config.grades,
        balance = getBalance(),
        payrollPct = getPayrollPct(),
        maxPayrollPct = config.maxPayrollPct,
        menu = loadMenu(false),
        personnel = loadPersonnel(),
        analytics = buildAnalytics(),
        ingredients = config.ingredients,
        products = config.products,
    }
end)

-- Refresh slices for the NUI without a full reopen.
lib.callback.register('yk_restaurant:server:refresh', function(source, data)
    local player = getPlayer(source)
    if not isManager(player) then return {} end
    local what = type(data) == 'table' and data.what or data
    if what == 'personnel' then return { personnel = loadPersonnel() } end
    if what == 'menu' then return { menu = loadMenu(false) } end
    if what == 'analytics' then return { analytics = buildAnalytics(), balance = getBalance() } end
    if what == 'stock' then return { stock = readStock(), balance = getBalance() } end
    return {}
end)

-- ---------------------------------------------------------------- personnel ops
-- Hire the nearest online player as crew (grade resolved client-side by manager).
lib.callback.register('yk_restaurant:server:hire', function(source, data)
    local player = getPlayer(source)
    if not isManager(player) then return { ok = false, msg = 'No permission.' } end

    local targetSrc = tonumber(data and data.targetId)
    local grade = clampInt(data and data.grade, 0, config.ownerGrade)
    if not targetSrc then return { ok = false, msg = 'No target.' } end

    -- A manager cannot hire at or above their own grade; owner can hire anyone below owner.
    local maxGrant = isOwner(player) and (config.ownerGrade - 1) or (gradeLevel(player) - 1)
    if grade > maxGrant then return { ok = false, msg = 'You cannot grant that rank.' } end
    if not config.grades or grade < 0 then return { ok = false, msg = 'Invalid rank.' } end

    local target = getPlayer(targetSrc)
    if not target then return { ok = false, msg = 'Player not found.' } end
    if target.PlayerData.job.name == config.job then return { ok = false, msg = 'Already employed here.' } end

    local ok = exports.qbx_core:SetJob(targetSrc, config.job, grade)
    if not ok then return { ok = false, msg = 'Failed to set job.' } end

    exports.qbx_core:Notify(targetSrc, ('You were hired at %s as %s.'):format(config.jobLabel, gradeName(grade)), 'success')
    exports.qbx_core:Notify(source, ('Hired %s.'):format(playerName(target)), 'success')
    return { ok = true, personnel = loadPersonnel() }
end)

lib.callback.register('yk_restaurant:server:setGrade', function(source, data)
    local player = getPlayer(source)
    if not isManager(player) then return { ok = false, msg = 'No permission.' } end
    local cid = data and data.citizenid
    if type(cid) ~= 'string' or (data.grade == nil) then return { ok = false, msg = 'Bad request.' } end
    local grade = clampInt(data.grade, 0, config.ownerGrade)

    -- Cannot act on someone at/above your own grade, nor promote to >= your grade.
    local target = exports.qbx_core:GetPlayerByCitizenId(cid)
    local targetGrade = target and target.PlayerData.job.grade.level or
        (MySQL.scalar.await('SELECT grade FROM player_groups WHERE citizenid = ? AND `group` = ? AND `type` = \'job\'', { cid, config.job }) or 0)

    local maxGrant = isOwner(player) and (config.ownerGrade - 1) or (gradeLevel(player) - 1)
    if not isOwner(player) and targetGrade >= gradeLevel(player) then
        return { ok = false, msg = 'You cannot manage that employee.' }
    end
    if grade > (isOwner(player) and config.ownerGrade or maxGrant) then
        return { ok = false, msg = 'You cannot grant that rank.' }
    end

    if target then
        if not exports.qbx_core:SetJob(target.PlayerData.source, config.job, grade) then
            return { ok = false, msg = 'Failed to update.' }
        end
        exports.qbx_core:Notify(target.PlayerData.source, ('Your rank at %s is now %s.'):format(config.jobLabel, gradeName(grade)), 'inform')
    else
        -- Offline: SetJob accepts a citizenid identifier.
        if not exports.qbx_core:SetJob(cid, config.job, grade) then
            return { ok = false, msg = 'Failed to update offline employee.' }
        end
    end
    return { ok = true, personnel = loadPersonnel() }
end)

lib.callback.register('yk_restaurant:server:fire', function(source, data)
    local player = getPlayer(source)
    if not isManager(player) then return { ok = false, msg = 'No permission.' } end
    local cid = data and data.citizenid
    if type(cid) ~= 'string' then return { ok = false, msg = 'Bad request.' } end
    if cid == player.PlayerData.citizenid then return { ok = false, msg = 'You cannot fire yourself.' } end

    local target = exports.qbx_core:GetPlayerByCitizenId(cid)
    local targetGrade = target and target.PlayerData.job.grade.level or
        (MySQL.scalar.await('SELECT grade FROM player_groups WHERE citizenid = ? AND `group` = ? AND `type` = \'job\'', { cid, config.job }) or 0)

    if not isOwner(player) and targetGrade >= gradeLevel(player) then
        return { ok = false, msg = 'You cannot fire that employee.' }
    end

    local identifier = target and target.PlayerData.source or cid
    if not exports.qbx_core:SetJob(identifier, 'unemployed', 0) then
        return { ok = false, msg = 'Failed to fire.' }
    end
    if target then exports.qbx_core:Notify(target.PlayerData.source, ('You were let go from %s.'):format(config.jobLabel), 'error') end

    -- Settle any accrued commission on the way out (paid only if they're online).
    local accrued = MySQL.scalar.await('SELECT accrued FROM yk_restaurant_payroll WHERE business = ? AND citizenid = ?', { BUSINESS, cid }) or 0
    if accrued > 0 and target then
        exports.qbx_core:AddMoney(target.PlayerData.source, 'bank', accrued, 'yk_restaurant_payroll')
        exports.qbx_core:Notify(target.PlayerData.source, ('Final pay: $%d.'):format(accrued), 'success')
        logExpense('payroll', accrued, ('Final pay %s'):format(playerName(target)))
    end
    MySQL.update.await('DELETE FROM yk_restaurant_payroll WHERE business = ? AND citizenid = ?', { BUSINESS, cid })
    return { ok = true, personnel = loadPersonnel() }
end)

-- Resolve nearest online player for hiring (client found the server id).
lib.callback.register('yk_restaurant:server:resolveTarget', function(source, targetId)
    local player = getPlayer(source)
    if not isManager(player) then return nil end
    local t = getPlayer(tonumber(targetId))
    if not t then return nil end
    return { id = t.PlayerData.source, name = playerName(t) }
end)

-- ============================================================================
-- Menu editing (owner)
-- ============================================================================
local function sanitizeIngredients(list)
    local valid = {}
    for _, group in pairs(config.ingredients) do
        for _, ing in ipairs(group) do valid[ing.item] = ing.label end
    end
    local out = {}
    if type(list) ~= 'table' then return out end
    for _, ing in ipairs(list) do
        local name = type(ing) == 'table' and ing.item
        local qty = clampInt(ing and ing.qty, 0, LIMITS.recipeQty)
        if name and valid[name] and qty > 0 then
            out[#out + 1] = { item = name, label = valid[name], qty = qty }
            if #out >= LIMITS.recipeItems then break end
        end
    end
    return out
end

lib.callback.register('yk_restaurant:server:menuSave', function(source, data)
    local player = getPlayer(source)
    if not isOwner(player) then return { ok = false, msg = 'Only the owner can edit the menu.' } end

    if type(data) ~= 'table' then return { ok = false, msg = 'Bad request.' } end
    local category = (data.category == 'drink') and 'drink' or 'food'
    local label = clampStr(data.label, LIMITS.label)
    local price = clampInt(data.price, 0, LIMITS.price)
    local icon = clampStr(data.icon, LIMITS.icon)
    if icon ~= '' and not icon:match('^https?://') then icon = '' end -- only allow web URLs
    local ingredients = sanitizeIngredients(data.ingredients)
    if label == '' then return { ok = false, msg = 'Name is required.' } end
    if #ingredients == 0 then return { ok = false, msg = 'Add at least one ingredient.' } end

    local id = tonumber(data.id)
    if id then
        MySQL.update.await('UPDATE yk_restaurant_menu SET category=?, label=?, price=?, icon=?, ingredients=? WHERE id=? AND business=?',
            { category, label, price, icon, json.encode(ingredients), id, BUSINESS })
    else
        MySQL.insert.await('INSERT INTO yk_restaurant_menu (business, category, label, price, icon, ingredients, active) VALUES (?,?,?,?,?,?,1)',
            { BUSINESS, category, label, price, icon, json.encode(ingredients) })
    end
    return { ok = true, menu = loadMenu(false) }
end)

lib.callback.register('yk_restaurant:server:menuToggle', function(source, data)
    local player = getPlayer(source)
    if not isOwner(player) then return { ok = false } end
    MySQL.update.await('UPDATE yk_restaurant_menu SET active = IF(active=1,0,1) WHERE id=? AND business=?', { tonumber(data.id), BUSINESS })
    return { ok = true, menu = loadMenu(false) }
end)

lib.callback.register('yk_restaurant:server:menuRemove', function(source, data)
    local player = getPlayer(source)
    if not isOwner(player) then return { ok = false } end
    MySQL.update.await('DELETE FROM yk_restaurant_menu WHERE id=? AND business=?', { tonumber(data.id), BUSINESS })
    return { ok = true, menu = loadMenu(false) }
end)

-- ============================================================================
-- Business account (owner)
-- ============================================================================
lib.callback.register('yk_restaurant:server:setPayrollPct', function(source, data)
    local player = getPlayer(source)
    if not isOwner(player) then return { ok = false } end
    local pct = math.max(0, math.min(config.maxPayrollPct, math.floor(tonumber(data.pct) or 0)))
    MySQL.update.await('UPDATE yk_restaurant_business SET payroll_pct = ? WHERE id = ?', { pct, BUSINESS })
    return { ok = true, payrollPct = pct }
end)

lib.callback.register('yk_restaurant:server:withdraw', function(source, data)
    local player = getPlayer(source)
    if not isOwner(player) then return { ok = false, msg = 'No permission.' } end
    local amount = clampInt(data and data.amount, 0, LIMITS.money)
    if amount <= 0 then return { ok = false, msg = 'Invalid amount.' } end
    if getBalance() < amount then return { ok = false, msg = 'Insufficient business funds.' } end
    addBalance(-amount)
    exports.qbx_core:AddMoney(source, 'bank', amount, 'yk_restaurant_withdraw')
    logExpense('withdraw', amount, ('Withdrawn by %s'):format(playerName(player)))
    return { ok = true, balance = getBalance() }
end)

lib.callback.register('yk_restaurant:server:deposit', function(source, data)
    local player = getPlayer(source)
    if not isOwner(player) then return { ok = false, msg = 'No permission.' } end
    local amount = clampInt(data and data.amount, 0, LIMITS.money)
    if amount <= 0 then return { ok = false, msg = 'Invalid amount.' } end
    if (exports.qbx_core:GetMoney(source, 'bank') or 0) < amount then return { ok = false, msg = 'Insufficient personal funds.' } end
    if not exports.qbx_core:RemoveMoney(source, 'bank', amount, 'yk_restaurant_deposit') then return { ok = false, msg = 'Payment failed.' } end
    addBalance(amount)
    return { ok = true, balance = getBalance() }
end)

-- ============================================================================
-- Wholesaler: order ingredients into the stash (charged to the business)
-- Usable from the wholesaler NPC or the management laptop.
-- ============================================================================
lib.callback.register('yk_restaurant:server:order', function(source, data)
    local player = getPlayer(source)
    if not isCrew(player) then return { ok = false, msg = 'Not employed here.' } end

    local fromLaptop = data and data.laptop
    if fromLaptop then
        if not isManager(player) then return { ok = false, msg = 'Managers only from the laptop.' } end
        if not nearPoint(source, 'management') then return { ok = false, msg = 'Too far from the office.' } end
    else
        if not nearPoint(source, 'wholesaler') then return { ok = false, msg = 'Too far from the wholesaler.' } end
    end

    -- Build a price lookup from config (ignore client-sent prices).
    local prices = {}
    for _, group in pairs(config.ingredients) do
        for _, ing in ipairs(group) do prices[ing.item] = ing.price end
    end

    local cart = data and data.cart
    if type(cart) ~= 'table' then return { ok = false, msg = 'Empty order.' } end

    local total, lines, seen = 0, {}, 0
    for item, qty in pairs(cart) do
        seen = seen + 1
        if seen > LIMITS.cartLines then break end
        qty = clampInt(qty, 0, LIMITS.orderQty)
        if type(item) == 'string' and prices[item] and qty > 0 then
            total = total + prices[item] * qty
            lines[#lines + 1] = { item = item, qty = qty }
        end
    end
    if total <= 0 then return { ok = false, msg = 'Empty order.' } end
    if getBalance() < total then return { ok = false, msg = 'Business funds too low.' } end

    -- Charge first, then deposit into the stash.
    addBalance(-total)
    for _, line in ipairs(lines) do
        exports.ox_inventory:AddItem(config.stash.id, line.item, line.qty)
    end
    logExpense('stock', total, ('%d line(s) ordered by %s'):format(#lines, playerName(player)))

    exports.qbx_core:Notify(source, ('Ordered ingredients for $%d.'):format(total), 'success')
    return { ok = true, balance = getBalance() }
end)

-- ============================================================================
-- Crafting (cooking station = food, drink station = drink)
-- Consumes ingredients from the crafter's own inventory.
-- ============================================================================
-- Active recipes for a station (food at cooking, drink at drink station).
lib.callback.register('yk_restaurant:server:craftList', function(source, category)
    local player = getPlayer(source)
    if not onDuty(player) then return { ok = false, msg = 'Clock in first.' } end
    category = category == 'drink' and 'drink' or 'food'
    if not nearPoint(source, category == 'drink' and 'drink' or 'cooking') then
        return { ok = false, msg = 'Use the correct station.' }
    end
    local out = {}
    for _, m in ipairs(loadMenu(true)) do
        if m.category == category then
            out[#out + 1] = { id = m.id, label = m.label, ingredients = m.ingredients }
        end
    end
    return { ok = true, menu = out }
end)

lib.callback.register('yk_restaurant:server:craft', function(source, data)
    local player = getPlayer(source)
    if not onDuty(player) then return { ok = false, msg = 'Clock in first.' } end

    local item = getMenuItem(tonumber(data and data.id))
    if not item then return { ok = false, msg = 'Unknown recipe.' } end

    local point = item.category == 'drink' and 'drink' or 'cooking'
    if not nearPoint(source, point) then return { ok = false, msg = 'Use the correct station.' } end

    -- Verify the crafter holds every ingredient.
    for _, ing in ipairs(item.ingredients) do
        local have = exports.ox_inventory:GetItemCount(source, ing.item) or 0
        if have < ing.qty then return { ok = false, msg = ('Missing %s.'):format(ing.label or ing.item) } end
    end

    local output = item.category == 'drink' and config.products.drink or config.products.food
    local metadata = { label = item.label, price = item.price, imageurl = item.icon ~= '' and item.icon or nil }

    if not exports.ox_inventory:CanCarryItem(source, output, 1, metadata) then
        return { ok = false, msg = 'Your hands are full.' }
    end

    -- Consume ingredients (re-check via RemoveItem return).
    for _, ing in ipairs(item.ingredients) do
        if not exports.ox_inventory:RemoveItem(source, ing.item, ing.qty) then
            return { ok = false, msg = 'Failed to consume ingredients.' }
        end
    end
    exports.ox_inventory:AddItem(source, output, 1, metadata)
    return { ok = true, label = item.label }
end)

-- ============================================================================
-- Register / POS
-- ============================================================================
-- Employee builds an order at the register; it becomes the pending order a
-- customer then pays for.
lib.callback.register('yk_restaurant:server:posMenu', function(source)
    local player = getPlayer(source)
    if not onDuty(player) then return { ok = false, msg = 'Clock in first.' } end
    if not nearPoint(source, 'register') then return { ok = false, msg = 'Too far from the register.' } end
    return { ok = true, menu = loadMenu(true) }
end)

lib.callback.register('yk_restaurant:server:createOrder', function(source, data)
    local player = getPlayer(source)
    if not onDuty(player) then return { ok = false, msg = 'Clock in first.' } end
    if not nearPoint(source, 'register') then return { ok = false, msg = 'Too far from the register.' } end

    local menu = loadMenu(true)
    local byId = {}
    for _, m in ipairs(menu) do byId[m.id] = m end

    local cart = data and data.cart
    if type(cart) ~= 'table' then return { ok = false, msg = 'Empty order.' } end

    local items, total, seen = {}, 0, 0
    for id, qty in pairs(cart) do
        seen = seen + 1
        if seen > LIMITS.cartLines then break end
        qty = clampInt(qty, 0, LIMITS.saleQty)
        local m = byId[tonumber(id)]
        if m and qty > 0 then
            total = total + m.price * qty
            items[#items + 1] = { label = m.label, price = m.price, qty = qty }
        end
    end
    if total <= 0 then return { ok = false, msg = 'Empty order.' } end

    pendingOrders[BUSINESS] = {
        items = items, total = total,
        employee_cid = player.PlayerData.citizenid,
        employee_name = playerName(player),
    }
    exports.qbx_core:Notify(source, ('Order rung up: $%d. Customer can now pay at the register.'):format(total), 'success')
    return { ok = true, total = total }
end)

-- Customer checks for / pays the pending order at the register.
lib.callback.register('yk_restaurant:server:getPendingOrder', function(source)
    if not nearPoint(source, 'register') then return { ok = false } end
    local order = pendingOrders[BUSINESS]
    if not order then return { ok = false, msg = 'No order is waiting.' } end
    return { ok = true, items = order.items, total = order.total, employee = order.employee_name }
end)

lib.callback.register('yk_restaurant:server:payOrder', function(source, data)
    if not nearPoint(source, 'register') then return { ok = false, msg = 'Too far from the register.' } end
    local order = pendingOrders[BUSINESS]
    if not order then return { ok = false, msg = 'No order is waiting.' } end

    local method = data and data.method == 'card' and 'card' or 'cash'
    local moneyType = method == 'card' and 'bank' or 'cash'
    if (exports.qbx_core:GetMoney(source, moneyType) or 0) < order.total then
        return { ok = false, msg = ('Not enough %s.'):format(method == 'card' and 'bank funds' or 'cash') }
    end
    if not exports.qbx_core:RemoveMoney(source, moneyType, order.total, 'yk_restaurant_purchase') then
        return { ok = false, msg = 'Payment failed.' }
    end

    -- Credit business, record the sale and accrue the employee's commission.
    addBalance(order.total)
    MySQL.insert('INSERT INTO yk_restaurant_sales (business, employee_cid, employee_name, items, total, method) VALUES (?,?,?,?,?,?)',
        { BUSINESS, order.employee_cid, order.employee_name, json.encode(order.items), order.total, method })

    local pct = getPayrollPct()
    local commission = math.floor(order.total * pct / 100)
    if commission > 0 then
        MySQL.query.await([[INSERT INTO yk_restaurant_payroll (business, citizenid, name, accrued)
            VALUES (?,?,?,?) ON DUPLICATE KEY UPDATE accrued = accrued + VALUES(accrued), name = VALUES(name)]],
            { BUSINESS, order.employee_cid, order.employee_name, commission })
    end

    pendingOrders[BUSINESS] = nil
    exports.qbx_core:Notify(source, ('Paid $%d by %s.'):format(order.total, method), 'success')

    -- Notify the cashier if they're online.
    local cashier = exports.qbx_core:GetPlayerByCitizenId(order.employee_cid)
    if cashier then exports.qbx_core:Notify(cashier.PlayerData.source, ('Customer paid $%d.'):format(order.total), 'success') end
    return { ok = true }
end)

-- ============================================================================
-- Clock in / out
-- ============================================================================
lib.callback.register('yk_restaurant:server:toggleDuty', function(source)
    local player = getPlayer(source)
    if not isCrew(player) then return { ok = false, msg = 'You do not work here.' } end
    if not nearPoint(source, 'clockin') then return { ok = false, msg = 'Use the time clock.' } end
    local newDuty = not player.PlayerData.job.onduty
    exports.qbx_core:SetJobDuty(source, newDuty)
    return { ok = true, onDuty = newDuty }
end)

-- ============================================================================
-- Payroll: pay each employee their accrued commission on an interval.
-- Online employees are paid immediately; offline balances carry until payout.
-- ============================================================================
local function runPayroll()
    local rows = MySQL.query.await('SELECT citizenid, name, accrued FROM yk_restaurant_payroll WHERE business = ? AND accrued > 0', { BUSINESS }) or {}
    for _, row in ipairs(rows) do
        local target = exports.qbx_core:GetPlayerByCitizenId(row.citizenid)
        if target then
            exports.qbx_core:AddMoney(target.PlayerData.source, 'bank', row.accrued, 'yk_restaurant_payroll')
            exports.qbx_core:Notify(target.PlayerData.source, ('Daily payroll: $%d deposited.'):format(row.accrued), 'success')
            MySQL.update('UPDATE yk_restaurant_payroll SET accrued = 0 WHERE business = ? AND citizenid = ?', { BUSINESS, row.citizenid })
            logExpense('payroll', row.accrued, ('Paid %s'):format(row.name))
        end
    end
end

CreateThread(function()
    local interval = config.payrollIntervalMinutes * 60000
    while true do
        Wait(interval)
        runPayroll()
    end
end)

-- Admin/console helper to force a payout.
lib.addCommand('runpayroll', { help = 'Force restaurant payroll payout', restricted = 'group.admin' }, function()
    runPayroll()
end)

AddEventHandler('playerDropped', function()
    -- Nothing persistent to clean (orders are per-business, not per-player).
end)
