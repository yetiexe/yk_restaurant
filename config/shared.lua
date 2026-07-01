-- ============================================================================
-- yk_restaurant — shared config
-- Player-owned / managed restaurant business for Qbox.
-- ============================================================================
return {
    -- The qbx job that backs this restaurant. Must exist in qbx_core/shared/jobs.lua.
    -- (yk_restaurant adds the 'burgershot' job there.)
    job = 'burgershot',
    jobLabel = 'Burger Shot',
    -- Unique business id used across the DB tables (one restaurant = one job here).
    business = 'burgershot',

    -- Grade gates -----------------------------------------------------------
    grades = {
        employee = 0, -- crew: clock in, craft, register
        cook     = 1,
        manager  = 2, -- + hire/fire crew, order stock, view analytics
        owner    = 3, -- + edit menu, payroll %, withdraw, hire managers
    },
    managementGrade = 2, -- grade >= this can open the management menu
    ownerGrade = 3,      -- grade >= this is treated as owner (full control)

    -- World points ----------------------------------------------------------
    locations = {
        register   = vec3(86.6, 285.25, 110.17),
        drink      = vec3(91.15, 282.3, 109.21),
        cooking    = vec3(89.79, 289.57, 109.21),
        stash      = vec3(86.75, 293.03, 109.21),
        clockin    = vec3(88.89, 294.99, 109.21),
        management = vec3(81.1, 296.41, 109.96),
        wholesaler = vec4(125.55, 296.06, 108.97, 70.0),
    },

    targetDistance = 2.0,
    interactDistance = 30.0, -- server-side anti-cheat distance for point actions

    -- Wholesaler NPC --------------------------------------------------------
    wholesalerPed = `mp_m_shopkeep_01`,

    -- Crafting --------------------------------------------------------------
    craftTime = 3000, -- ms (3 second crafting timer for food & drink)

    -- Ingredient stash (registered via ox_inventory RegisterStash) ----------
    stash = {
        id = 'yk_restaurant_burgershot',
        label = 'Burger Shot — Stock',
        slots = 100,
        weight = 500000, -- 500kg
    },

    -- Generic output items that carry a custom (per-menu-item) label + icon
    -- via ox_inventory metadata.label / metadata.imageurl.
    products = {
        food = 'yk_food',
        drink = 'yk_drink',
    },

    -- Wholesaler ingredient catalogue. `item` must match an ox_inventory item.
    -- `price` is the per-unit wholesale cost charged to the business balance.
    ingredients = {
        food = {
            { item = 'cheese',      label = 'Cheese',      price = 3 },
            { item = 'lettuce',     label = 'Lettuce',     price = 2 },
            { item = 'ground_beef', label = 'Ground Beef', price = 5 },
            { item = 'tomato',      label = 'Tomato',      price = 2 },
            { item = 'burger_bun',  label = 'Burger Bun',  price = 2 },
        },
        drink = {
            { item = 'soda_syrup',   label = 'Soda Syrup',   price = 4 },
            { item = 'iced_tea_bag', label = 'Iced Tea Bag', price = 3 },
        },
    },

    -- Economy ---------------------------------------------------------------
    defaultPayrollPct = 10,  -- % of an employee's own sales, paid out daily
    maxPayrollPct = 40,
    payrollIntervalMinutes = 1440, -- "daily" (real-time). Lower for testing.
    startingBalance = 5000,  -- seeded into the business account on first run

    -- A small set of starter menu items seeded on first run. Owners edit these
    -- freely in the management menu. `icon` is an image URL shown in the NUI and
    -- carried onto the crafted item (leave '' and set your own per item in-game;
    -- the host must be reachable by the game's CEF browser).
    defaultMenu = {
        {
            category = 'food', label = 'Cheeseburger', price = 12, icon = '',
            ingredients = {
                { item = 'burger_bun', qty = 1 },
                { item = 'ground_beef', qty = 1 },
                { item = 'cheese', qty = 1 },
            },
        },
        {
            category = 'food', label = 'Garden Burger', price = 14, icon = '',
            ingredients = {
                { item = 'burger_bun', qty = 1 },
                { item = 'ground_beef', qty = 1 },
                { item = 'lettuce', qty = 1 },
                { item = 'tomato', qty = 1 },
            },
        },
        {
            category = 'drink', label = 'Fountain Soda', price = 5, icon = '',
            ingredients = {
                { item = 'soda_syrup', qty = 1 },
            },
        },
        {
            category = 'drink', label = 'Iced Tea', price = 5, icon = '',
            ingredients = {
                { item = 'iced_tea_bag', qty = 1 },
            },
        },
    },
}
