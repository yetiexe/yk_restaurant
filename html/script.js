(() => {
  const RES = (typeof GetParentResourceName === 'function') ? GetParentResourceName() : 'yk_restaurant';
  const $ = (s, r = document) => r.querySelector(s);
  const $$ = (s, r = document) => Array.from(r.querySelectorAll(s));
  const money = (n) => '$' + (Number(n) || 0).toLocaleString('en-US');
  const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

  async function post(name, data = {}) {
    try {
      const r = await fetch(`https://${RES}/${name}`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(data)
      });
      return await r.json();
    } catch (e) { return {}; }
  }

  // ---------------- state ----------------
  let MG = null;          // management boot data
  let POS = { menu: [], cat: 'food', cart: {} };
  let ORD = { ingredients: { food: [], drink: [] }, laptop: false, cart: {} };

  const root = $('#root');
  const screens = { management: $('#app-management'), pos: $('#app-pos'), order: $('#app-order') };

  function refreshSelectUi(select) {
    const ui = select.nextElementSibling?.classList?.contains('select-ui') ? select.nextElementSibling : null;
    if (!ui) return;
    const selected = select.selectedOptions[0] || select.options[0];
    $('.select-value', ui).textContent = selected ? selected.textContent : '';
    $('.select-menu', ui).innerHTML = Array.from(select.options).map((opt) =>
      `<button type="button" class="select-option ${opt.selected ? 'selected' : ''}" data-value="${esc(opt.value)}">
        <span>${esc(opt.textContent)}</span>
        ${opt.selected ? '<i class="fa-solid fa-check"></i>' : ''}
      </button>`
    ).join('');
    $$('.select-option', ui).forEach((option) => {
      option.onclick = () => {
        select.value = option.dataset.value;
        refreshSelectUi(select);
        ui.classList.remove('open');
        select.dispatchEvent(new Event('change', { bubbles: true }));
      };
    });
  }

  function closeSelectUis(except = null) {
    $$('.select-ui.open').forEach((ui) => {
      if (ui !== except) ui.classList.remove('open');
    });
  }

  function enhanceSelects(scope = document) {
    $$('select', scope).forEach((select) => {
      if (!select.dataset.customSelect) {
        select.dataset.customSelect = '1';
        select.classList.add('native-select');

        const ui = document.createElement('div');
        ui.className = 'select-ui';
        ui.innerHTML = `
          <button type="button" class="select-trigger" aria-haspopup="listbox" aria-expanded="false">
            <span class="select-value"></span>
            <i class="fa-solid fa-chevron-down"></i>
          </button>
          <div class="select-menu" role="listbox"></div>`;
        select.insertAdjacentElement('afterend', ui);

        $('.select-trigger', ui).onclick = () => {
          const open = !ui.classList.contains('open');
          closeSelectUis(ui);
          ui.classList.toggle('open', open);
          $('.select-trigger', ui).setAttribute('aria-expanded', String(open));
        };
      }
      refreshSelectUi(select);
    });
  }

  document.addEventListener('pointerdown', (e) => {
    if (!e.target.closest('.select-ui')) closeSelectUis();
  });

  function stepNumberInput(input, direction) {
    const min = input.min === '' ? -Infinity : Number(input.min);
    const max = input.max === '' ? Infinity : Number(input.max);
    const step = input.step === '' || input.step === 'any' ? 1 : Number(input.step);
    const amount = Number.isFinite(step) && step > 0 ? step : 1;
    if (input.value === '') {
      const nextEmpty = Number.isFinite(min) ? min : (direction > 0 ? amount : 0);
      input.value = Number.isInteger(nextEmpty) ? String(nextEmpty) : String(Number(nextEmpty.toFixed(4)));
      input.dispatchEvent(new Event('input', { bubbles: true }));
      input.dispatchEvent(new Event('change', { bubbles: true }));
      return;
    }
    const base = Number(input.value);
    let next = base + (direction * amount);
    if (Number.isFinite(min)) next = Math.max(min, next);
    if (Number.isFinite(max)) next = Math.min(max, next);
    input.value = Number.isInteger(next) ? String(next) : String(Number(next.toFixed(4)));
    input.dispatchEvent(new Event('input', { bubbles: true }));
    input.dispatchEvent(new Event('change', { bubbles: true }));
  }

  function enhanceNumberInputs(scope = document) {
    $$('input[type="number"]', scope).forEach((input) => {
      if (input.dataset.customNumber) return;
      input.dataset.customNumber = '1';
      input.classList.add('number-input');

      const wrap = document.createElement('div');
      wrap.className = 'number-ui';
      input.insertAdjacentElement('beforebegin', wrap);
      wrap.appendChild(input);
      wrap.insertAdjacentHTML('beforeend', `
        <div class="number-steps" aria-hidden="true">
          <button type="button" class="number-step" data-step="up" tabindex="-1"><i class="fa-solid fa-chevron-up"></i></button>
          <button type="button" class="number-step" data-step="down" tabindex="-1"><i class="fa-solid fa-chevron-down"></i></button>
        </div>`);

      $('[data-step="up"]', wrap).onclick = () => stepNumberInput(input, 1);
      $('[data-step="down"]', wrap).onclick = () => stepNumberInput(input, -1);
    });
  }

  function showScreen(name) {
    Object.values(screens).forEach((s) => s.classList.remove('visible'));
    root.classList.remove('hidden');
    if (screens[name]) screens[name].classList.add('visible');
  }
  function close() {
    root.classList.add('hidden');
    Object.values(screens).forEach((s) => s.classList.remove('visible'));
    post('close');
  }

  // ===================================================================
  //  MANAGEMENT
  // ===================================================================
  function gradeOptions(maxLevel) {
    // grades is name->level; build sorted <=maxLevel
    const list = Object.entries(MG.grades).map(([name, lvl]) => ({ name, lvl }))
      .filter((g) => g.lvl <= maxLevel).sort((a, b) => a.lvl - b.lvl);
    return list.map((g) => `<option value="${g.lvl}">${esc(g.name)}</option>`).join('');
  }
  function gradeName(level) {
    const found = Object.entries(MG.grades).find(([, lvl]) => lvl === level);
    return found ? found[0] : level;
  }
  function maxGrant() {
    // owner can grant up to owner-1 (managers); manager up to own grade-1
    const ownerLvl = MG.grades.owner;
    if (MG.role === 'owner') return ownerLvl - 1;
    return (MG.grades.manager) - 1; // managers can hire crew/cook
  }

  function renderManagement() {
    $('#brand-role').textContent = MG.role;
    document.body.dataset.role = MG.role;
    $$('.owner-only').forEach((el) => { el.style.display = MG.role === 'owner' ? '' : 'none'; });
    $('#mg-balance').textContent = money(MG.balance);
    renderDashboard();
    renderPersonnel();
    renderMenu();
    if (MG.role === 'owner') resetMenuForm();
    renderOrderCatalogue();
    renderAccount();
    enhanceSelects(screens.management);
    enhanceNumberInputs(screens.management);
  }

  function renderDashboard() {
    const a = MG.analytics || {};
    const cards = [
      { k: 'Business Balance', i: 'building-columns', v: money(MG.balance), c: 'good' },
      { k: 'Revenue (24h)', i: 'sack-dollar', v: money(a.revenueDay), c: '' },
      { k: 'Total Revenue', i: 'chart-line', v: money(a.revenueAll), c: '' },
      { k: 'Profit', i: 'scale-balanced', v: money(a.profit), c: (a.profit || 0) >= 0 ? 'good' : 'bad' },
    ];
    $('#dash-cards').innerHTML = cards.map((c) =>
      `<div class="card"><div class="k"><i class="fa-solid fa-${c.i}"></i> ${c.k}</div><div class="v ${c.c}">${c.v}</div></div>`).join('');

    const top = a.topItems || [];
    const maxQ = Math.max(1, ...top.map((t) => t.qty));
    $('#dash-top').innerHTML = top.length ? top.map((t) =>
      `<div class="bar-row"><div class="lbl">${esc(t.label)}</div><div class="bar-track"><div class="bar-fill" style="width:${(t.qty / maxQ * 100).toFixed(0)}%"></div></div><div class="val">${t.qty} sold</div></div>`
    ).join('') : '<div class="empty">No sales yet.</div>';

    const emp = a.perEmployee || [];
    const maxR = Math.max(1, ...emp.map((e) => e.revenue));
    $('#dash-emp').innerHTML = emp.length ? emp.map((e) =>
      `<div class="bar-row"><div class="lbl">${esc(e.name)}</div><div class="bar-track"><div class="bar-fill" style="width:${(e.revenue / maxR * 100).toFixed(0)}%"></div></div><div class="val">${money(e.revenue)}</div></div>`
    ).join('') : '<div class="empty">No sales yet.</div>';
  }

  function renderPersonnel() {
    $('#hire-grade').innerHTML = gradeOptions(maxGrant());
    const body = $('#staff-body');
    const rows = (MG.personnel || []).map((p) => {
      const canManage = MG.role === 'owner' || p.grade < MG.grades.manager;
      const sel = canManage
        ? `<select class="grade-select" data-cid="${esc(p.citizenid)}">${
            Object.entries(MG.grades).sort((a, b) => a[1] - b[1])
              .map(([n, l]) => `<option value="${l}" ${l === p.grade ? 'selected' : ''}>${esc(n)}</option>`).join('')
          }</select>`
        : esc(gradeName(p.grade));
      const fire = canManage ? `<button class="btn danger small" data-fire="${esc(p.citizenid)}"><i class="fa-solid fa-user-minus"></i></button>` : '';
      return `<tr>
        <td>${esc(p.name)}</td>
        <td>${sel}</td>
        <td><span class="tag ${p.online ? 'on' : 'off'}">${p.online ? 'Online' : 'Offline'}</span></td>
        <td><div class="tbl-actions">${fire}</div></td>
      </tr>`;
    }).join('');
    body.innerHTML = rows || '<tr><td colspan="4" class="empty">No employees.</td></tr>';

    $$('#staff-body [data-fire]').forEach((b) => b.onclick = async () => {
      const res = await post('fire', { citizenid: b.dataset.fire });
      if (res.ok) { MG.personnel = res.personnel; renderPersonnel(); }
      else alert(res.msg || 'Failed.');
    });
    $$('#staff-body .grade-select').forEach((s) => s.onchange = async () => {
      const res = await post('setGrade', { citizenid: s.dataset.cid, grade: Number(s.value) });
      if (res.ok) { MG.personnel = res.personnel; renderPersonnel(); }
      else { alert(res.msg || 'Failed.'); renderPersonnel(); }
    });
    enhanceSelects(screens.management);
  }

  $('#hire-nearest').onclick = async () => {
    const res = await post('hireNearest', { grade: Number($('#hire-grade').value) });
    if (res.ok) { MG.personnel = res.personnel; renderPersonnel(); }
    else alert(res.msg || 'Failed.');
  };

  // ---- menu editor (owner) ----
  function ingredientPicker(selected) {
    const all = [...MG.ingredients.food, ...MG.ingredients.drink];
    return all.map((i) => `<option value="${esc(i.item)}" ${i.item === selected ? 'selected' : ''}>${esc(i.label)}</option>`).join('');
  }
  function addIngRow(item = '', qty = 1) {
    const row = document.createElement('div');
    row.className = 'ing-row';
    row.innerHTML = `<select class="ing-item">${ingredientPicker(item)}</select>
      <input type="number" class="ing-qty" min="1" value="${qty}" />
      <button type="button" class="btn ghost small rm"><i class="fa-solid fa-xmark"></i></button>`;
    row.querySelector('.rm').onclick = () => row.remove();
    $('#m-ingredients').appendChild(row);
    enhanceSelects(row);
    enhanceNumberInputs(row);
  }
  function resetMenuForm() {
    $('#m-id').value = '';
    $('#m-label').value = '';
    $('#m-category').value = 'food';
    $('#m-price').value = 10;
    $('#m-icon').value = '';
    $('#m-icon-preview').src = '';
    $('#m-ingredients').innerHTML = '';
    addIngRow();
    $('#menu-form-title').textContent = 'Add Item';
    enhanceSelects(screens.management);
    enhanceNumberInputs(screens.management);
  }
  function editMenuItem(it) {
    $('#m-id').value = it.id;
    $('#m-label').value = it.label;
    $('#m-category').value = it.category;
    $('#m-price').value = it.price;
    $('#m-icon').value = it.icon || '';
    $('#m-icon-preview').src = it.icon || '';
    $('#m-ingredients').innerHTML = '';
    (it.ingredients || []).forEach((ing) => addIngRow(ing.item, ing.qty));
    if (!it.ingredients || !it.ingredients.length) addIngRow();
    $('#menu-form-title').textContent = 'Edit Item';
    enhanceSelects(screens.management);
    enhanceNumberInputs(screens.management);
  }
  function renderMenu() {
    const list = $('#menu-list');
    list.innerHTML = (MG.menu || []).map((it) => `
      <div class="menu-item ${it.active ? '' : 'inactive'}">
        <img src="${esc(it.icon || '')}" alt="" onerror="this.style.visibility='hidden'" />
        <div class="mi-info">
          <div class="mi-name">${esc(it.label)}</div>
          <div class="mi-meta">${esc(it.category)} · ${money(it.price)} · ${(it.ingredients || []).map((i) => i.qty + 'x ' + esc(i.label)).join(', ')}</div>
        </div>
        <button class="btn ghost small" data-edit="${it.id}" title="Edit ${esc(it.label)}" aria-label="Edit ${esc(it.label)}"><i class="fa-solid fa-pen"></i></button>
        <button class="btn ghost small" data-toggle="${it.id}" title="${it.active ? 'Hide' : 'Show'} ${esc(it.label)}" aria-label="${it.active ? 'Hide' : 'Show'} ${esc(it.label)}"><i class="fa-solid fa-power-off"></i></button>
        <button class="btn danger small" data-del="${it.id}" title="Remove ${esc(it.label)}" aria-label="Remove ${esc(it.label)}"><i class="fa-solid fa-trash"></i></button>
      </div>`).join('') || '<div class="empty">No menu items.</div>';

    $$('#menu-list [data-edit]').forEach((b) => b.onclick = () => editMenuItem(MG.menu.find((m) => m.id == b.dataset.edit)));
    $$('#menu-list [data-toggle]').forEach((b) => b.onclick = async () => {
      const res = await post('menuToggle', { id: Number(b.dataset.toggle) });
      if (res.ok) { MG.menu = res.menu; renderMenu(); }
    });
    $$('#menu-list [data-del]').forEach((b) => b.onclick = async () => {
      if (!confirm('Remove this item?')) return;
      const res = await post('menuRemove', { id: Number(b.dataset.del) });
      if (res.ok) { MG.menu = res.menu; renderMenu(); resetMenuForm(); }
    });
  }
  $('#m-add-ing').onclick = () => addIngRow();
  $('#m-reset').onclick = () => resetMenuForm();
  $('#m-icon').oninput = (e) => { $('#m-icon-preview').src = e.target.value; };
  $('#menu-form').onsubmit = async (e) => {
    e.preventDefault();
    const ingredients = $$('#m-ingredients .ing-row').map((r) => ({
      item: r.querySelector('.ing-item').value,
      qty: Number(r.querySelector('.ing-qty').value),
    })).filter((i) => i.item && i.qty > 0);
    const payload = {
      id: $('#m-id').value ? Number($('#m-id').value) : null,
      category: $('#m-category').value,
      label: $('#m-label').value,
      price: Number($('#m-price').value),
      icon: $('#m-icon').value,
      ingredients,
    };
    const res = await post('menuSave', payload);
    if (res.ok) { MG.menu = res.menu; renderMenu(); resetMenuForm(); }
    else alert(res.msg || 'Failed.');
  };

  // ---- stock ----
  async function loadStock() {
    const res = await post('refresh', { what: 'stock' });
    const wrap = $('#stock-list');
    const stock = res.stock || [];
    if (res.balance != null) { MG.balance = res.balance; $('#mg-balance').textContent = money(MG.balance); }
    wrap.innerHTML = stock.length ? stock.map((s) =>
      `<div class="stock-cell"><div class="sc-name">${esc(s.label)}</div><div class="sc-count">${s.count}</div></div>`
    ).join('') : '<div class="empty">Stash is empty.</div>';
  }

  // ---- order stock (laptop) ----
  function catalogueHTML(ingredients) {
    const group = (title, list) => `<div class="cat-group"><h3>${title}</h3>${
      list.map((i) => `<div class="cat-line">
        <div class="cl-name">${esc(i.label)}</div>
        <div class="cl-price">${money(i.price)}/ea</div>
        <input type="number" min="0" value="0" data-item="${esc(i.item)}" data-price="${i.price}" />
      </div>`).join('')
    }</div>`;
    return group('Food', ingredients.food) + group('Drink', ingredients.drink);
  }
  function wireCatalogue(scope, totalEl) {
    $$(`${scope} input[data-item]`).forEach((inp) => inp.oninput = () => {
      let total = 0;
      $$(`${scope} input[data-item]`).forEach((i) => { total += (Number(i.value) || 0) * Number(i.dataset.price); });
      $(totalEl).textContent = money(total);
    });
  }
  function collectCart(scope) {
    const cart = {};
    $$(`${scope} input[data-item]`).forEach((i) => { const q = Number(i.value) || 0; if (q > 0) cart[i.dataset.item] = q; });
    return cart;
  }
  function renderOrderCatalogue() {
    $('#order-catalogue').innerHTML = catalogueHTML(MG.ingredients);
    wireCatalogue('#order-catalogue', '#order-total');
    $('#order-total').textContent = money(0);
    enhanceNumberInputs($('#order-catalogue'));
  }
  $('#order-confirm').onclick = async () => {
    const cart = collectCart('#order-catalogue');
    if (!Object.keys(cart).length) return alert('Nothing selected.');
    const res = await post('order', { cart, laptop: true });
    if (res.ok) {
      if (res.balance != null) { MG.balance = res.balance; $('#mg-balance').textContent = money(MG.balance); }
      renderOrderCatalogue();
      alert('Order placed. Ingredients delivered to the stash.');
    } else alert(res.msg || 'Failed.');
  };

  // ---- account ----
  function renderAccount() {
    $('#acc-pct').value = MG.payrollPct;
    $('#acc-pct').max = MG.maxPayrollPct;
    $('#acc-balance').textContent = money(MG.balance);
    enhanceNumberInputs(screens.management);
  }
  $('#acc-pct-save').onclick = async () => {
    const res = await post('setPayrollPct', { pct: Number($('#acc-pct').value) });
    if (res.ok) { MG.payrollPct = res.payrollPct; renderAccount(); alert('Payroll updated.'); }
  };
  $('#acc-deposit').onclick = async () => {
    const res = await post('deposit', { amount: Number($('#acc-amount').value) });
    if (res.ok) { MG.balance = res.balance; $('#mg-balance').textContent = money(MG.balance); renderAccount(); $('#acc-amount').value = ''; }
    else alert(res.msg || 'Failed.');
  };
  $('#acc-withdraw').onclick = async () => {
    const res = await post('withdraw', { amount: Number($('#acc-amount').value) });
    if (res.ok) { MG.balance = res.balance; $('#mg-balance').textContent = money(MG.balance); renderAccount(); $('#acc-amount').value = ''; }
    else alert(res.msg || 'Failed.');
  };

  // ---- nav ----
  $$('.nav-btn').forEach((btn) => btn.onclick = () => {
    $$('.nav-btn').forEach((b) => b.classList.remove('active'));
    btn.classList.add('active');
    const tab = btn.dataset.tab;
    $$('.tab').forEach((t) => t.classList.toggle('active', t.dataset.tab === tab));
    if (tab === 'stock') loadStock();
    if (tab === 'dashboard') refreshAnalytics();
  });
  async function refreshAnalytics() {
    const res = await post('refresh', { what: 'analytics' });
    if (res.analytics) MG.analytics = res.analytics;
    if (res.balance != null) MG.balance = res.balance;
    $('#mg-balance').textContent = money(MG.balance);
    renderDashboard();
  }

  // ===================================================================
  //  POS (REGISTER)
  // ===================================================================
  function renderPOS() {
    $$('.pos-tab').forEach((t) => t.classList.toggle('active', t.dataset.cat === POS.cat));
    const items = POS.menu.filter((m) => m.category === POS.cat);
    $('#pos-items').innerHTML = items.length ? items.map((m) =>
      `<button type="button" class="pos-card ${POS.cart[m.id] ? 'selected' : ''}" data-id="${m.id}">
        <span class="pc-count">${POS.cart[m.id] || ''}</span>
        <span class="pc-media">
          <img src="${esc(m.icon || '')}" alt="" onerror="this.style.display='none'" />
          <i class="fa-solid fa-utensils"></i>
        </span>
        <span class="pc-name">${esc(m.label)}</span>
        <span class="pc-price">${money(m.price)}</span>
      </button>`).join('') : '<div class="empty">No items in this category.</div>';
    $$('#pos-items .pos-card').forEach((c) => c.onclick = () => {
      const id = Number(c.dataset.id);
      POS.cart[id] = (POS.cart[id] || 0) + 1;
      renderPOS();
    });
    renderCart();
  }
  function renderCart() {
    const wrap = $('#pos-cart-list');
    const ids = Object.keys(POS.cart);
    let total = 0;
    wrap.innerHTML = ids.length ? ids.map((id) => {
      const m = POS.menu.find((x) => x.id == id);
      if (!m) return '';
      const qty = POS.cart[id];
      total += m.price * qty;
      return `<div class="cart-row">
        <div class="cr-main">
          <div class="cr-name">${esc(m.label)}</div>
          <div class="cr-sub">${money(m.price * qty)}</div>
        </div>
        <button class="qty-btn" data-dec="${id}" aria-label="Remove one ${esc(m.label)}">-</button>
        <span class="cr-qty">${qty}</span>
        <button class="qty-btn" data-inc="${id}" aria-label="Add one ${esc(m.label)}">+</button>
      </div>`;
    }).join('') : '<div class="empty">Tap items to add.</div>';
    $('#pos-total').textContent = money(total);
    $('#pos-charge').disabled = ids.length === 0;
    $('#pos-clear').disabled = ids.length === 0;
    $$('#pos-cart-list [data-inc]').forEach((b) => b.onclick = () => { POS.cart[b.dataset.inc]++; renderPOS(); });
    $$('#pos-cart-list [data-dec]').forEach((b) => b.onclick = () => {
      const id = b.dataset.dec;
      POS.cart[id]--;
      if (POS.cart[id] <= 0) delete POS.cart[id];
      renderPOS();
    });
  }
  $$('.pos-tab').forEach((t) => t.onclick = () => { POS.cat = t.dataset.cat; renderPOS(); });
  $('#pos-clear').onclick = () => {
    POS.cart = {};
    renderPOS();
  };
  $('#pos-charge').onclick = async () => {
    if (!Object.keys(POS.cart).length) return alert('No items selected.');
    const res = await post('createOrder', { cart: POS.cart });
    if (res.ok) { close(); }
    else alert(res.msg || 'Failed.');
  };

  // ===================================================================
  //  WHOLESALE ORDER (standalone)
  // ===================================================================
  function renderWholesale() {
    $('#wholesale-catalogue').innerHTML = catalogueHTML(ORD.ingredients);
    wireCatalogue('#wholesale-catalogue', '#wholesale-total');
    $('#wholesale-total').textContent = money(0);
    enhanceNumberInputs($('#app-order'));
  }
  $('#wholesale-confirm').onclick = async () => {
    const cart = collectCart('#wholesale-catalogue');
    if (!Object.keys(cart).length) return alert('Nothing selected.');
    const res = await post('order', { cart, laptop: false });
    if (res.ok) { close(); }
    else alert(res.msg || 'Failed.');
  };

  // ===================================================================
  //  MESSAGE BUS
  // ===================================================================
  window.addEventListener('message', (ev) => {
    const d = ev.data || {};
    if (d.action === 'close') return close();
    if (d.action !== 'open') return;

    if (d.screen === 'management') {
      MG = d.data;
      MG.menu = MG.menu || [];
      MG.personnel = MG.personnel || [];
      renderManagement();
      // default to dashboard tab
      $$('.nav-btn').forEach((b) => b.classList.toggle('active', b.dataset.tab === 'dashboard'));
      $$('.tab').forEach((t) => t.classList.toggle('active', t.dataset.tab === 'dashboard'));
      showScreen('management');
    } else if (d.screen === 'pos') {
      POS = { menu: d.data.menu || [], cat: 'food', cart: {} };
      renderPOS();
      showScreen('pos');
    } else if (d.screen === 'order') {
      ORD = { ingredients: d.data.ingredients || { food: [], drink: [] }, laptop: !!d.data.laptop, cart: {} };
      renderWholesale();
      showScreen('order');
    }
  });

  document.addEventListener('keydown', (e) => {
    if (e.key !== 'Escape') return;
    if ($('.select-ui.open')) {
      closeSelectUis();
      return;
    }
    close();
  });
  $$('[data-close]').forEach((b) => b.onclick = close);
})();
