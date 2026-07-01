local config = require 'config.shared'

-- ============================================================================
-- yk_restaurant — client
-- World points (ox_target), NUI screens (management / POS / wholesale order),
-- crafting progress and the customer checkout flow.
-- ============================================================================

local L = config.locations
local nuiOpen = false
local wholesaler = { ped = nil, blip = nil }
local targets = {}

local function notify(msg, kind) exports.qbx_core:Notify(msg, kind or 'inform') end

local function isCrew()
    local job = QBX and QBX.PlayerData and QBX.PlayerData.job
    return job ~= nil and job.name == config.job
end
local function gradeLevel()
    local job = QBX and QBX.PlayerData and QBX.PlayerData.job
    return (job and job.grade and job.grade.level) or 0
end

-- ---------------------------------------------------------------- NUI plumbing
local function closeNui()
    if not nuiOpen then return end
    nuiOpen = false
    SetNuiFocus(false, false)
    SendNUIMessage({ action = 'close' })
end

local function openNui(screen, data)
    nuiOpen = true
    SetNuiFocus(true, true)
    SendNUIMessage({ action = 'open', screen = screen, data = data })
end

RegisterNUICallback('close', function(_, cb)
    closeNui()
    cb({})
end)

-- Generic bridge: forward NUI payload to a server callback, return its result.
local function bridge(name, serverCb)
    RegisterNUICallback(name, function(data, cb)
        cb(lib.callback.await(serverCb, false, data) or {})
    end)
end

bridge('refresh', 'yk_restaurant:server:refresh')
bridge('hire', 'yk_restaurant:server:hire')
bridge('setGrade', 'yk_restaurant:server:setGrade')
bridge('fire', 'yk_restaurant:server:fire')
bridge('menuSave', 'yk_restaurant:server:menuSave')
bridge('menuToggle', 'yk_restaurant:server:menuToggle')
bridge('menuRemove', 'yk_restaurant:server:menuRemove')
bridge('setPayrollPct', 'yk_restaurant:server:setPayrollPct')
bridge('withdraw', 'yk_restaurant:server:withdraw')
bridge('deposit', 'yk_restaurant:server:deposit')
bridge('order', 'yk_restaurant:server:order')
bridge('createOrder', 'yk_restaurant:server:createOrder')

-- Hire-by-nearest: the client finds the closest player, the server resolves them.
local function nearestServerId()
    local me = cache.ped
    local mc = GetEntityCoords(me)
    local best, bestD
    for _, pid in ipairs(GetActivePlayers()) do
        local ped = GetPlayerPed(pid)
        if ped ~= me and DoesEntityExist(ped) then
            local d = #(GetEntityCoords(ped) - mc)
            if d <= 5.0 and (not bestD or d < bestD) then best, bestD = pid, d end
        end
    end
    return best and GetPlayerServerId(best) or nil
end

RegisterNUICallback('hireNearest', function(data, cb)
    local id = nearestServerId()
    if not id then return cb({ ok = false, msg = 'No one nearby.' }) end
    local resolved = lib.callback.await('yk_restaurant:server:resolveTarget', false, id)
    if not resolved then return cb({ ok = false, msg = 'Could not resolve player.' }) end
    local res = lib.callback.await('yk_restaurant:server:hire', false, { targetId = resolved.id, grade = data and data.grade })
    res.hiredName = resolved.name
    cb(res or {})
end)

-- ---------------------------------------------------------------- crafting
local function craftAt(category, point)
    if not isCrew() then return notify('You do not work here.', 'error') end
    local data = lib.callback.await('yk_restaurant:server:craftList', false, category)
    if not data or not data.ok then return notify((data and data.msg) or 'Unavailable.', 'error') end

    local options = {}
    for _, m in ipairs(data.menu) do
        local parts = {}
        for _, ing in ipairs(m.ingredients) do parts[#parts + 1] = ('%dx %s'):format(ing.qty, ing.label or ing.item) end
        options[#options + 1] = {
            title = m.label,
            description = table.concat(parts, ', '),
            icon = category == 'drink' and 'mug-hot' or 'burger',
            onSelect = function()
                local ok = lib.progressCircle({
                    duration = config.craftTime,
                    label = ('Preparing %s...'):format(m.label),
                    useWhileDead = false,
                    canCancel = true,
                    disable = { move = true, car = true, combat = true },
                    anim = { dict = 'amb@prop_human_bbq@male@base', clip = 'base' },
                })
                if not ok then return notify('Cancelled.', 'error') end
                local res = lib.callback.await('yk_restaurant:server:craft', false, { id = m.id })
                if res and res.ok then notify(('Made %s.'):format(res.label), 'success')
                else notify((res and res.msg) or 'Failed.', 'error') end
            end,
        }
    end
    if #options == 0 then return notify('No recipes available.', 'error') end
    lib.registerContext({ id = 'yk_restaurant_craft_' .. category, title = category == 'drink' and 'Drink Station' or 'Cooking Station', options = options })
    lib.showContext('yk_restaurant_craft_' .. category)
end

-- ---------------------------------------------------------------- register (customer pay)
local function customerCheckout()
    local order = lib.callback.await('yk_restaurant:server:getPendingOrder', false)
    if not order or not order.ok then return notify((order and order.msg) or 'No order is waiting.', 'error') end

    local lines = {}
    for _, it in ipairs(order.items) do lines[#lines + 1] = ('%dx %s'):format(it.qty, it.label) end
    local options = {
        { title = ('Total: $%d'):format(order.total), description = table.concat(lines, ', '), disabled = true },
        {
            title = 'Pay with Cash', icon = 'money-bill', onSelect = function()
                local res = lib.callback.await('yk_restaurant:server:payOrder', false, { method = 'cash' })
                if not (res and res.ok) then notify((res and res.msg) or 'Failed.', 'error') end
            end,
        },
        {
            title = 'Pay with Card', icon = 'credit-card', onSelect = function()
                local res = lib.callback.await('yk_restaurant:server:payOrder', false, { method = 'card' })
                if not (res and res.ok) then notify((res and res.msg) or 'Failed.', 'error') end
            end,
        },
    }
    lib.registerContext({ id = 'yk_restaurant_checkout', title = 'Checkout', options = options })
    lib.showContext('yk_restaurant_checkout')
end

-- ---------------------------------------------------------------- open screens
local function openManagement()
    local boot = lib.callback.await('yk_restaurant:server:openManagement', false)
    if not boot or not boot.ok then return notify('You are not authorized.', 'error') end
    openNui('management', boot)
end

local function openRegisterStaff()
    local res = lib.callback.await('yk_restaurant:server:posMenu', false)
    if not res or not res.ok then return notify((res and res.msg) or 'Unavailable.', 'error') end
    openNui('pos', res)
end

local function openWholesaler()
    if not isCrew() then return notify('You do not work here.', 'error') end
    openNui('order', { ingredients = config.ingredients, laptop = false })
end

-- ---------------------------------------------------------------- world setup
local function addSphere(name, coords, label, icon, onSelect, canInteract)
    local id = exports.ox_target:addSphereZone({
        coords = vector3(coords.x, coords.y, coords.z),
        radius = config.targetDistance,
        debug = false,
        options = {
            {
                name = name,
                label = label,
                icon = icon,
                onSelect = onSelect,
                canInteract = canInteract,
            },
        },
    })
    targets[#targets + 1] = id
end

local function setupTargets()
    -- Management office (manager+)
    addSphere('yk_rest_mgmt', L.management, 'Management Terminal', 'fa-solid fa-laptop', openManagement,
        function() return isCrew() and gradeLevel() >= config.managementGrade end)

    -- Register: staff ring-up + customer checkout
    addSphere('yk_rest_reg_staff', L.register, 'Open Register', 'fa-solid fa-cash-register', openRegisterStaff,
        function() return isCrew() end)
    addSphere('yk_rest_reg_pay', L.register, 'Pay / Checkout', 'fa-solid fa-receipt', customerCheckout)

    -- Cooking + drink stations
    addSphere('yk_rest_cook', L.cooking, 'Cook Food', 'fa-solid fa-burger',
        function() craftAt('food', 'cooking') end, function() return isCrew() end)
    addSphere('yk_rest_drink', L.drink, 'Make Drink', 'fa-solid fa-mug-hot',
        function() craftAt('drink', 'drink') end, function() return isCrew() end)

    -- Stock stash
    addSphere('yk_rest_stash', L.stash, 'Open Stock', 'fa-solid fa-box',
        function() exports.ox_inventory:openInventory('stash', config.stash.id) end,
        function() return isCrew() end)

    -- Time clock
    addSphere('yk_rest_clock', L.clockin, 'Clock In / Out', 'fa-solid fa-clock', function()
        local res = lib.callback.await('yk_restaurant:server:toggleDuty', false)
        if res and res.ok then notify(res.onDuty and 'You are now ON duty.' or 'You are now OFF duty.', res.onDuty and 'success' or 'inform')
        else notify((res and res.msg) or 'Failed.', 'error') end
    end, function() return isCrew() end)
end

local function spawnWholesaler()
    local w = L.wholesaler
    lib.requestModel(config.wholesalerPed, 5000)
    local ped = CreatePed(4, config.wholesalerPed, w.x, w.y, w.z, w.w, false, false)
    SetModelAsNoLongerNeeded(config.wholesalerPed)
    SetEntityInvincible(ped, true)
    FreezeEntityPosition(ped, true)
    SetBlockingOfNonTemporaryEvents(ped, true)
    TaskStartScenarioInPlace(ped, 'WORLD_HUMAN_CLIPBOARD', 0, true)
    wholesaler.ped = ped

    exports.ox_target:addLocalEntity(ped, {
        {
            name = 'yk_rest_wholesale',
            label = 'Order Ingredients',
            icon = 'fa-solid fa-truck-ramp-box',
            distance = 2.5,
            canInteract = function() return isCrew() end,
            onSelect = openWholesaler,
        },
    })

    local blip = AddBlipForCoord(w.x, w.y, w.z)
    SetBlipSprite(blip, 478)
    SetBlipColour(blip, 47)
    SetBlipScale(blip, 0.8)
    SetBlipAsShortRange(blip, true)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentSubstringPlayerName('Food Wholesaler')
    EndTextCommandSetBlipName(blip)
    wholesaler.blip = blip
end

local function teardown()
    if nuiOpen then SetNuiFocus(false, false) end
    for _, id in ipairs(targets) do exports.ox_target:removeZone(id) end
    targets = {}
    if wholesaler.ped and DoesEntityExist(wholesaler.ped) then
        exports.ox_target:removeLocalEntity(wholesaler.ped)
        DeleteEntity(wholesaler.ped)
    end
    if wholesaler.blip and DoesBlipExist(wholesaler.blip) then RemoveBlip(wholesaler.blip) end
    wholesaler = { ped = nil, blip = nil }
end

local didSetup = false
local function init()
    if didSetup then return end
    didSetup = true
    setupTargets()
    spawnWholesaler()
end

-- Fires when the resource (re)starts while the player is already in-game (live restart).
AddEventHandler('onResourceStart', function(resource)
    if GetCurrentResourceName() ~= resource then return end
    init()
end)

-- Fires on a normal connect: the resource is already running at server boot, so
-- onResourceStart never fires for the joining client. Run setup once the player is
-- loaded so the targets/NPC always exist without a manual re-ensure.
CreateThread(function()
    while not (QBX and QBX.PlayerData and QBX.PlayerData.citizenid) do Wait(250) end
    init()
end)
RegisterNetEvent('QBCore:Client:OnPlayerLoaded', init)
RegisterNetEvent('qbx_core:client:playerLoggedIn', init)

AddEventHandler('onResourceStop', function(resource)
    if GetCurrentResourceName() ~= resource then return end
    teardown()
end)
