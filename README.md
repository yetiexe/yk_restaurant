# yk_restaurant

A player-owned / managed **restaurant business** for the [Qbox](https://github.com/Qbox-project) framework.
Employees clock in, order ingredients from a wholesaler, cook food & mix drinks from
configurable recipes, and ring customers up at the register. Owners run the whole thing
from an NUI management terminal — hiring, menu design, stock, payroll and live analytics.

## Features

- 🧑‍🍳 **Full staff loop** — clock in/out, craft food & drinks (with progress + timer), shared stock stash.
- 🧾 **Register / POS** — staff build an order, the customer pays by cash or card (third-eye).
- 🍔 **Custom menu items** — owners create items with their own name, price, **icon URL** and recipe. No new inventory items to register.
- 📦 **Wholesaler** — order ingredients in person or from the management laptop; charged to the business account.
- 💼 **Management NUI** — dashboard analytics, personnel (hire/fire/rank), menu editor, stock, ordering, business account.
- 💰 **Payroll** — each employee earns a configurable % of their own sales, paid out on an interval.
- 🔒 **Server-authoritative** — all money, permissions and inputs validated server-side.

## Requirements

- [qbx_core](https://github.com/Qbox-project/qbx_core)
- [ox_lib](https://github.com/overextended/ox_lib)
- [ox_target](https://github.com/overextended/ox_target)
- [ox_inventory](https://github.com/overextended/ox_inventory)
- [oxmysql](https://github.com/overextended/oxmysql)

## Installation

**1. Drop the resource** into your resources folder and add it to `server.cfg`
(after the dependencies above are ensured):

```cfg
ensure yk_restaurant
```

**2. Add the job** to `qbx_core/shared/jobs.lua`:

```lua
['burgershot'] = {
    label = 'Burger Shot',
    defaultDuty = false,
    offDutyPay = false,
    grades = {
        [0] = { name = 'employee', payment = 0 },
        [1] = { name = 'cook',     payment = 0 },
        [2] = { name = 'manager',  payment = 0 },
        [3] = { name = 'owner', isboss = true, bankAuth = true, payment = 0 },
    },
},
```

**3. Add the items** to `ox_inventory/data/items.lua`:

```lua
-- Ingredients
['cheese']       = { label = 'Cheese',       weight = 50,  description = 'A wedge of cheese.' },
['lettuce']      = { label = 'Lettuce',      weight = 60,  description = 'A head of crisp lettuce.' },
['ground_beef']  = { label = 'Ground Beef',  weight = 120, description = 'Fresh ground beef.' },
['tomato']       = { label = 'Tomato',       weight = 40,  description = 'A ripe tomato.' },
['burger_bun']   = { label = 'Burger Bun',   weight = 40,  description = 'A soft sesame bun.' },
['soda_syrup']   = { label = 'Soda Syrup',   weight = 80,  description = 'Concentrated soda syrup for the fountain.' },
['iced_tea_bag'] = { label = 'Iced Tea Bag', weight = 10,  description = 'A bag for brewing iced tea.' },

-- Generic prepared products. Per-item name + icon are set at craft time via
-- metadata.label / metadata.imageurl, so one item can represent any menu item.
['yk_food'] = {
    label = 'Prepared Food', weight = 220,
    client = { status = { hunger = 200000 }, anim = 'eating', prop = 'burger', usetime = 3000, notification = 'That hit the spot.' },
},
['yk_drink'] = {
    label = 'Prepared Drink', weight = 350,
    client = {
        status = { thirst = 200000 },
        anim = { dict = 'mp_player_intdrink', clip = 'loop_bottle' },
        prop = { model = `prop_ld_can_01`, pos = vec3(0.01, 0.01, 0.06), rot = vec3(5.0, 5.0, -180.5) },
        usetime = 3000, notification = 'Refreshing.',
    },
},
```

> Ingredient items ship without images. To give an ingredient a custom icon, add
> `client = { image = 'https://<host>/your-icon.png' }` to it. The host must be
> reachable by the game's in-game (CEF) browser — many image hosts block hotlinking.

**4. Database** — tables are created automatically on first start:
`yk_restaurant_business`, `yk_restaurant_menu`, `yk_restaurant_sales`,
`yk_restaurant_expenses`, `yk_restaurant_payroll`.

**5. Set the first owner** from the server console, then hire everyone else in-game:

```
setjob <playerId> burgershot 3
```

The ingredient **stash** is registered automatically at runtime (gated to the
`burgershot` job) — no `stashes.lua` entry required.

## Gameplay loop

1. **Clock in** at the time clock (third-eye) — required for register, crafting and stock.
2. **Order ingredients** from the wholesaler NPC, or remotely from the management
   terminal (managers+). Cost is charged to the business account and the ingredients
   are delivered straight into the restaurant **stash**.
3. **Withdraw ingredients** from the stash into your own inventory.
4. **Craft** food at the cooking station and drinks at the drink station (3s timer).
   Crafting consumes the recipe's ingredients from your inventory and gives the
   finished item (carrying its custom name + icon).
5. **Ring up** a customer at the register (staff option) by selecting items — the total
   is auto-calculated. The customer then **pays** at the same register (cash or card,
   third-eye → "Pay / Checkout").
6. The sale credits the business account, is recorded for analytics, and accrues the
   cashier's commission. **Payroll** (a configurable % of each employee's own sales) is
   paid out on an interval ("daily").

## Management terminal (manager / owner)

Third-eye the management point. NUI app with:

- **Dashboard** — balance, 24h / total revenue, profit, top sellers, per-employee sales.
- **Personnel** — hire the nearest player, change ranks, fire (managers can only manage
  ranks below themselves; the owner can manage anyone below owner).
- **Menu** *(owner)* — create/edit/enable/remove menu items: name, category, price,
  custom **icon URL**, and a recipe built from the available ingredients.
- **Stock** — live ingredient counts in the stash.
- **Order Stock** — order ingredients from the laptop (managers+).
- **Account** *(owner)* — set payroll %, deposit/withdraw business funds.

## Custom food items & icons

Crafted items use two generic ox_inventory items, `yk_food` and `yk_drink`, whose
per-item **label** and **image** are set at craft time via ox_inventory
`metadata.label` / `metadata.imageurl`. So any menu item the owner creates shows its own
name and icon in the inventory without registering new ox_inventory items. The icon host
must be reachable by the game's CEF browser.

## Configuration

Everything lives in `config/shared.lua`:

| Key | Purpose |
|-----|---------|
| `job` / `business` | Backing qbx job + business id (must match the job you added). |
| `locations` | World coordinates for every interaction point (see below). |
| `ingredients` | Wholesaler catalogue + per-unit prices. |
| `defaultMenu` | Starter menu items seeded on first run. |
| `defaultPayrollPct` / `maxPayrollPct` | Commission rate + cap. |
| `payrollIntervalMinutes` | Payout cadence (default 1440 = daily). |
| `startingBalance` | Business account seed. |
| `craftTime` | Crafting timer (ms). |

Admin command `/runpayroll` (ace `group.admin`) forces an immediate payout.

### Coordinates (`locations`)

| Point            | Coords |
|------------------|--------|
| Register         | 86.6, 285.25, 110.17 |
| Drink station    | 91.15, 282.3, 109.21 |
| Cooking station  | 89.79, 289.57, 109.21 |
| Stock stash      | 86.75, 293.03, 109.21 |
| Time clock       | 88.89, 294.99, 109.21 |
| Management       | 81.1, 296.41, 109.96 |
| Wholesaler NPC   | 125.55, 296.06, 108.97, h70 |

## Security

Every server callback re-checks the caller's job, grade and on-duty state, and
distance-checks the player against the point they claim to be using. All money moves
server-side, and all values from the UI (quantities, prices, IDs, names, icon URLs)
are bounds-clamped and type-checked server-side — a modified client cannot inject
out-of-range or malformed values. All SQL is parameterized.

Out of scope (as with most FiveM resources): defending against a player physically
teleporting to a point. The distance checks assume a reasonably trusted position and
should be paired with a server-side anti-cheat if that is a concern.

## License

Released under the [MIT License](LICENSE) — free to use, modify and redistribute.
