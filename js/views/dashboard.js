// لوحة التحكم — سجل الديون (الصفحة الرئيسية) مطابق للصورة المرفقة + الرسوم البيانية
import { $, $$, esc, fmt, todayISO, parseDate, relTime, beep, printHTML } from '../utils.js';
import { store } from '../store.js';
import { money, toast, openModal } from '../components.js';
import { accountBalance, ACCOUNT_KINDS, OP_TYPES, balanceLabels } from '../accounting.js';
import { go } from '../app.js';

let currentFilter = 'all'; // 'all' | 'customer' | 'supplier' | 'general' | custom category
let searchQuery = '';
let showSearch = false;
let currentSort = 'default'; // 'default' | 'name' | 'balDesc' | 'balAsc' | 'ops'
let viewMode = 'ledger'; // 'ledger' (سجل الديون) | 'analytics' (الرسوم البيانية)

export function render(container, params, state) {
  const settings = store.settings();
  const txs = store.transactions();
  const allAccounts = store.accounts(true);
  const currs = store.getCurrencies();

  // حساب عدد العمليات لكل حساب
  const txCount = {};
  for (const t of txs) {
    if (t.accountId) txCount[t.accountId] = (txCount[t.accountId] || 0) + 1;
  }

  // وضع عرض الرسوم البيانية والإحصائيات
  if (viewMode === 'analytics') {
    return renderAnalyticsView(container, settings, txs, allAccounts, currs);
  }

  // تصفية الحسابات حسب التصنيف
  let filtered = allAccounts.slice();
  if (currentFilter === 'customer') {
    filtered = filtered.filter(a => a.kind === 'customer');
  } else if (currentFilter === 'supplier') {
    filtered = filtered.filter(a => a.kind === 'supplier');
  } else if (currentFilter === 'general') {
    filtered = filtered.filter(a => a.kind === 'general');
  } else if (currentFilter !== 'all') {
    filtered = filtered.filter(a => a.category === currentFilter || a.kind === currentFilter);
  }

  // تصفية البحث الفوري
  if (searchQuery.trim()) {
    const q = searchQuery.trim().toLowerCase();
    filtered = filtered.filter(a => (a.name || '').toLowerCase().includes(q) || (a.phone || '').includes(q));
  }

  // الترتيب
  if (currentSort === 'name') {
    filtered.sort((a, b) => a.name.localeCompare(b.name, 'ar'));
  } else if (currentSort === 'balDesc') {
    filtered.sort((a, b) => accountBalance(b, txs) - accountBalance(a, txs));
  } else if (currentSort === 'balAsc') {
    filtered.sort((a, b) => accountBalance(a, txs) - accountBalance(b, txs));
  } else if (currentSort === 'ops') {
    filtered.sort((a, b) => ((txCount[b.id] || b.sampleOps || 0) - (txCount[a.id] || a.sampleOps || 0)));
  }

  // حساب إجمالي "عليه" و "له" والرصيد الصافي
  let totalReceivable = 0; // عليه
  let totalPayable = 0;    // له
  for (const a of filtered) {
    const bal = accountBalance(a, txs);
    if (bal > 0) totalReceivable += bal;
    else if (bal < 0) totalPayable += Math.abs(bal);
  }
  const netBalance = totalReceivable - totalPayable;
  let netText = '';
  if (netBalance > 0) {
    netText = `الرصيد عليه : ${fmt(netBalance)} محلي`;
  } else if (netBalance < 0) {
    netText = `الرصيد له : ${fmt(Math.abs(netBalance))} محلي`;
  } else {
    netText = `الرصيد خالص : 0 محلي`;
  }

  const filterLabel = currentFilter === 'all' ? 'عام' :
    currentFilter === 'customer' ? 'عملاء' :
    currentFilter === 'supplier' ? 'موردين' :
    currentFilter === 'general' ? 'حسابات عامة' : currentFilter;

  container.innerHTML = `
    <div class="ledger-view-container" dir="rtl">
      <div class="view-head dashboard-summary-head" style="margin-bottom:10px">
        <div><div class="view-title">الرئيسية 📊</div><small>ملخص الحسابات والديون</small></div>
        <button class="btn primary sm" id="ledger-btn-add-acc-title">＋ حساب جديد</button>
      </div>
      <div class="stats-grid dashboard-summary-stats" style="margin-bottom:12px">
        <div class="stat-card"><div class="stat-label">الحسابات</div><div class="stat-value">${allAccounts.length}</div></div>
        <div class="stat-card"><div class="stat-label">عليه</div><div class="stat-value">${fmt(totalReceivable)}</div></div>
        <div class="stat-card"><div class="stat-label">له</div><div class="stat-value">${fmt(totalPayable)}</div></div>
      </div>
      <!-- الشريط العلوي المطابق للصورة -->
      <header class="ledger-topbar">
        <div class="ledger-topbar-left">
          <button class="ledger-icon-btn" id="ledger-btn-sidebar" title="القائمة الرئيسية">
            <span style="font-size:22px">☰</span>
          </button>
          <button class="ledger-category-dropdown-btn" id="ledger-btn-category">
            <span>${esc(filterLabel)}</span>
            <span style="font-size:14px">▾</span>
          </button>
        </div>

        <div class="ledger-topbar-right">
          <button class="ledger-icon-btn" id="ledger-btn-search-toggle" title="بحث سريع">
            <span>🔍</span>
          </button>
          <button class="ledger-icon-btn ledger-pdf-btn" id="ledger-btn-report" title="تقرير وكشف حسابات (PDF / Excel)">
            <span>📑</span>
          </button>
          <button class="ledger-icon-btn" id="ledger-btn-more" title="خيارات إضافية">
            <span>⋮</span>
          </button>
        </div>
      </header>

      <!-- مربع البحث السريع عند فتحه -->
      <div id="ledger-search-box" class="ledger-search-box ${showSearch ? '' : 'hidden'}">
        <input type="text" id="ledger-search-input" placeholder="ابحث بالاسم أو رقم الهاتف..." value="${esc(searchQuery)}" autofocus />
        <button class="btn ghost sm" id="ledger-search-clear">✖</button>
      </div>

      <!-- شريط عدد الحسابات أسفل الشريط العلوي -->
      <div class="ledger-count-bar">
        <span>👥 (${filtered.length})</span>
      </div>

      <!-- قائمة بطاقات الحسابات والديون -->
      <div class="ledger-list" id="ledger-cards-list">
        ${filtered.length === 0 ? `
          <div style="text-align:center;padding:48px 16px;color:var(--text3)">
            <div style="font-size:48px;margin-bottom:12px">📭</div>
            <div style="font-size:16px;font-weight:700">لا توجد حسابات مطابقة للتصفية</div>
            <button class="btn primary sm" style="margin-top:14px" id="ledger-btn-add-acc-empty">➕ إضافة حساب جديد</button>
          </div>
        ` : filtered.map(a => renderLedgerCard(a, txs, txCount)).join('')}
      </div>

      <!-- شريط ملخص الأرصدة السفلي الثابت المطابق تماماً للصورة -->
      <footer class="ledger-bottom-bar">
        <div class="ledger-bottom-info">
          <div class="ledger-bottom-row-1">
            <span>عليه: ${fmt(totalReceivable)}</span>
            <span>له: ${fmt(totalPayable)}</span>
          </div>
          <div class="ledger-bottom-row-2">
            <span>${netText}</span>
          </div>
        </div>

        <button class="ledger-bottom-add-btn" id="ledger-bottom-quick-add" title="تسجيل عملية جديدة">
          <!-- أيقونة مستند مع زائد -->
          <svg viewBox="0 0 24 24">
            <path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8l-6-6zm2 14h-3v3h-2v-3H8v-2h3v-3h2v3h3v2zm-3-7V3.5L18.5 9H13z"/>
          </svg>
        </button>
        <button class="ledger-bottom-add-btn ledger-account-add-btn" id="ledger-bottom-add-account" title="إضافة حساب جديد">＋</button>
      </footer>
    </div>
  `;

  // ربط الأحداث
  bindLedgerEvents(container, allAccounts, filtered, txs);
}

function renderLedgerCard(a, txs, txCount) {
  const bal = accountBalance(a, txs);
  const isDebtor = bal > 0;
  const isCreditor = bal < 0;
  const isZero = bal === 0;

  const arrowClass = isDebtor ? 'alayh' : isCreditor ? 'lahu' : 'khalis';
  const arrowIcon = isDebtor ? '▼' : isCreditor ? '▲' : '✓';

  const ops = (txCount[a.id] || a.sampleOps || 0);

  return `
    <div class="ledger-card" data-account-id="${esc(a.id)}">
      <!-- الجانب الأيسر: مربع اتجاه السهم (أحمر عليه / أخضر له / رمادي خالص) -->
      <div class="ledger-card-left">
        <div class="ledger-arrow-box ${arrowClass}">
          ${arrowIcon}
        </div>
      </div>

      <!-- المنتصف: اسم الحساب في الأعلى والمبلغ في الأسفل -->
      <div class="ledger-card-center">
        <div class="ledger-card-name">${esc(a.name)}</div>
        <div class="ledger-card-amount">${fmt(Math.abs(bal))}</div>
      </div>

      <!-- الجانب الأيمن: أيقونة السند الزرقاء مع رقم عدد العمليات -->
      <div class="ledger-card-right">
        <button class="ledger-doc-btn" data-quick-tx="${esc(a.id)}" title="تسجيل عملية لهذا الحساب">
          <svg class="ledger-doc-icon" viewBox="0 0 24 24" fill="currentColor">
            <path d="M14 2H6c-1.1 0-2 .9-2 2v16c0 1.1.9 2 2 2h12c1.1 0 2-.9 2-2V8l-6-6zm2 14h-3v3h-2v-3H8v-2h3v-3h2v3h3v2zm-3-7V3.5L18.5 9H13z"/>
          </svg>
          <span class="ledger-count-badge">${ops}</span>
        </button>
      </div>
    </div>
  `;
}

function bindLedgerEvents(container, allAccounts, filtered, txs) {
  // فتح القائمة الجانبية
  const btnSidebar = $('#ledger-btn-sidebar', container);
  if (btnSidebar) {
    btnSidebar.onclick = () => {
      document.documentElement.dataset.sidebar = 'open';
    };
  }

  // تصفية التصنيف (عام، عملاء، موردين...)
  const btnCategory = $('#ledger-btn-category', container);
  if (btnCategory) {
    btnCategory.onclick = () => openCategorySelectorModal();
  }

  // تبديل مربع البحث
  const btnSearch = $('#ledger-btn-search-toggle', container);
  const searchBox = $('#ledger-search-box', container);
  const searchInput = $('#ledger-search-input', container);
  if (btnSearch && searchBox) {
    btnSearch.onclick = () => {
      showSearch = !showSearch;
      searchBox.classList.toggle('hidden', !showSearch);
      if (showSearch && searchInput) {
        searchInput.focus();
      } else {
        searchQuery = '';
        render(container, {}, {});
      }
    };
  }
  if (searchInput) {
    searchInput.oninput = (e) => {
      searchQuery = e.target.value;
      render(container, {}, {});
      const inp = $('#ledger-search-input', container);
      if (inp) {
        inp.focus();
        inp.setSelectionRange(inp.value.length, inp.value.length);
      }
    };
  }
  const btnClearSearch = $('#ledger-search-clear', container);
  if (btnClearSearch) {
    btnClearSearch.onclick = () => {
      searchQuery = '';
      showSearch = false;
      render(container, {}, {});
    };
  }

  // تقرير وكشف حسابات PDF / Excel
  const btnReport = $('#ledger-btn-report', container);
  if (btnReport) {
    btnReport.onclick = () => openExportReportModal(filtered, txs);
  }

  // خيارات إضافية (⋮)
  const btnMore = $('#ledger-btn-more', container);
  if (btnMore) {
    btnMore.onclick = () => openMoreOptionsMenu();
  }

  // بطاقات الحسابات
  const cardsList = $('#ledger-cards-list', container);
  if (cardsList) {
    cardsList.onclick = (e) => {
      // زر العملية السريعة
      const qBtn = e.target.closest('[data-quick-tx]');
      if (qBtn) {
        e.stopPropagation();
        const accId = qBtn.dataset.quickTx;
        go('transactions', { new: 1, accountId: accId });
        return;
      }
      // النقر على البطاقة يفتح كشف حساب العميل
      const card = e.target.closest('.ledger-card');
      if (card && card.dataset.accountId) {
        go('accounts', { id: card.dataset.accountId });
      }
    };
  }

  // زر إضافة حساب إذا كانت القائمة فارغة
  const btnAddEmpty = $('#ledger-btn-add-acc-empty', container);
  if (btnAddEmpty) {
    btnAddEmpty.onclick = () => go('accounts', { new: 1 });
  }
  const btnAddTitle = $('#ledger-btn-add-acc-title', container);
  if (btnAddTitle) btnAddTitle.onclick = () => go('accounts', { new: 1 });

  // زر الإضافة السريع في الشريط السفلي
  const btnBottomAdd = $('#ledger-bottom-quick-add', container);
  if (btnBottomAdd) {
    btnBottomAdd.onclick = () => {
      openQuickCreateMenu();
    };
  }
  const btnBottomAccount = $('#ledger-bottom-add-account', container);
  if (btnBottomAccount) btnBottomAccount.onclick = () => go('accounts', { new: 1 });
}

function openCategorySelectorModal() {
  const customCategories = store.col('categories') || [];
  const options = [
    { id: 'all', label: 'عام (جميع الحسابات)', icon: '👥' },
    { id: 'customer', label: 'العملاء', icon: '👤' },
    { id: 'supplier', label: 'الموردون', icon: '🏭' },
    { id: 'general', label: 'حسابات عامة', icon: '🏦' },
    ...customCategories.map(c => ({ id: c.name, label: c.name, icon: '📁' }))
  ];

  const m = openModal({
    title: '📂 اختر التصنيف / المجموعة',
    cls: 'sm',
    body: `
      <div style="display:flex;flex-direction:column;gap:8px">
        ${options.map(opt => `
          <button class="btn ${currentFilter === opt.id ? 'primary' : 'ghost'}" data-cat-choice="${esc(opt.id)}" style="justify-content:flex-start;padding:12px 14px;font-size:15px">
            <span>${opt.icon}</span>
            <span style="margin-right:8px">${esc(opt.label)}</span>
            ${currentFilter === opt.id ? '<span style="margin-left:auto">✓</span>' : ''}
          </button>
        `).join('')}
      </div>
    `,
    foot: `<button class="btn ghost" data-close>إلغاء</button>`
  });

  m.overlay.onclick = (e) => {
    const choice = e.target.closest('[data-cat-choice]');
    if (choice) {
      currentFilter = choice.dataset.catChoice;
      m.close();
      const c = $('#view');
      if (c) render(c, {}, {});
    }
  };
}

function openExportReportModal(accounts, txs) {
  const m = openModal({
    title: '📑 كشف سجل الديون والتقارير',
    cls: 'md',
    body: `
      <div style="display:flex;flex-direction:column;gap:12px;padding:4px">
        <div style="font-weight:700;color:var(--text2)">اختر نوع التصدير أو المعاينة:</div>
        
        <button class="btn primary" id="btn-export-pdf" style="padding:14px;font-size:15px;justify-content:flex-start">
          <span>📄</span>
          <span style="margin-right:8px">طباعة كشف سجل الديون / حفظ كـ PDF</span>
        </button>

        <button class="btn soft" id="btn-export-excel" style="padding:14px;font-size:15px;justify-content:flex-start">
          <span>📊</span>
          <span style="margin-right:8px">تصدير إلى جدول Excel (ملف CSV)</span>
        </button>

        <button class="btn ghost" id="btn-export-share-summary" style="padding:14px;font-size:15px;justify-content:flex-start">
          <span>📲</span>
          <span style="margin-right:8px">مشاركة ملخص الأرصدة عبر واتساب أو رسالة</span>
        </button>
      </div>
    `,
    foot: `<button class="btn ghost" data-close>إغلاق</button>`
  });

  $('#btn-export-pdf', m.overlay).onclick = () => {
    m.close();
    printLedgerTable(accounts, txs);
  };

  $('#btn-export-excel', m.overlay).onclick = () => {
    m.close();
    exportLedgerCSV(accounts, txs);
  };

  $('#btn-export-share-summary', m.overlay).onclick = () => {
    m.close();
    shareLedgerSummary(accounts, txs);
  };
}

function printLedgerTable(accounts, txs) {
  let totalDebit = 0;
  let totalCredit = 0;

  const rows = accounts.map((a, i) => {
    const bal = accountBalance(a, txs);
    const debit = bal > 0 ? bal : 0;
    const credit = bal < 0 ? Math.abs(bal) : 0;
    totalDebit += debit;
    totalCredit += credit;
    const status = bal > 0 ? 'عليه' : bal < 0 ? 'له' : 'خالص';

    return `
      <tr>
        <td style="text-align:center">${i + 1}</td>
        <td><b>${esc(a.name)}</b></td>
        <td>${esc(a.phone || '—')}</td>
        <td style="text-align:center">${esc(status)}</td>
        <td style="text-align:left;color:#b91c1c;font-weight:bold">${debit ? fmt(debit) : '—'}</td>
        <td style="text-align:left;color:#15803d;font-weight:bold">${credit ? fmt(credit) : '—'}</td>
      </tr>
    `;
  }).join('');

  const net = totalDebit - totalCredit;
  const netLabel = net > 0 ? `صافي مستحق (عليه): ${fmt(net)} محلي` : net < 0 ? `صافي التزام (له): ${fmt(Math.abs(net))} محلي` : `الرصيد خالص: 0 محلي`;

  const html = `
    <table border="1" cellpadding="8" style="width:100%;border-collapse:collapse;margin-top:12px">
      <thead>
        <tr style="background:#0284c7;color:#fff">
          <th>م</th>
          <th>اسم الحساب</th>
          <th>رقم الهاتف</th>
          <th>الحالة</th>
          <th>عليه (مدين)</th>
          <th>له (دائن)</th>
        </tr>
      </thead>
      <tbody>
        ${rows}
      </tbody>
      <tfoot>
        <tr style="background:#f1f5f9;font-weight:bold">
          <td colspan="4" style="text-align:center">الإجمالي العام</td>
          <td style="text-align:left;color:#b91c1c">${fmt(totalDebit)}</td>
          <td style="text-align:left;color:#15803d">${fmt(totalCredit)}</td>
        </tr>
        <tr style="background:#e2e8f0;font-weight:bold;font-size:14px">
          <td colspan="6" style="text-align:center">${netLabel}</td>
        </tr>
      </tfoot>
    </table>
  `;

  printHTML('كشف سجل الديون والأرصدة', html);
}

function exportLedgerCSV(accounts, txs) {
  let csv = '\uFEFFم,اسم الحساب,الهاتف,التصنيف,الحالة,عليه,له,الرصيد الصافي\n';
  accounts.forEach((a, i) => {
    const bal = accountBalance(a, txs);
    const debit = bal > 0 ? bal : 0;
    const credit = bal < 0 ? Math.abs(bal) : 0;
    const status = bal > 0 ? 'عليه' : bal < 0 ? 'له' : 'خالص';
    csv += `"${i + 1}","${(a.name || '').replace(/"/g, '""')}","${a.phone || ''}","${a.category || a.kind || ''}","${status}","${debit}","${credit}","${bal}"\n`;
  });

  const blob = new Blob([csv], { type: 'text/csv;charset=utf-8;' });
  const url = URL.createObjectURL(blob);
  const link = document.createElement('a');
  link.setAttribute('href', url);
  link.setAttribute('download', `سجل_الديون_${todayISO()}.csv`);
  document.body.appendChild(link);
  link.click();
  document.body.removeChild(link);
  toast('تم تصدير ملف Excel بنجاح 📊');
}

function shareLedgerSummary(accounts, txs) {
  let totalDebit = 0;
  let totalCredit = 0;
  for (const a of accounts) {
    const bal = accountBalance(a, txs);
    if (bal > 0) totalDebit += bal;
    else if (bal < 0) totalCredit += Math.abs(bal);
  }
  const net = totalDebit - totalCredit;
  const netText = net > 0 ? `الرصيد عليه : ${fmt(net)} محلي` : net < 0 ? `الرصيد له : ${fmt(Math.abs(net))} محلي` : `الرصيد خالص : 0 محلي`;

  const text = `📊 *ملخص سجل الديون والأرصدة*\n📅 التاريخ: ${new Date().toLocaleDateString('ar-YE')}\n👥 عدد الحسابات: ${accounts.length}\n---------------------------\n🔴 إجمالي (عليه): ${fmt(totalDebit)}\n🟢 إجمالي (له): ${fmt(totalCredit)}\n⚖️ ${netText}\n---------------------------\nصادر من نظام إدارة البيانات`;

  if (navigator.share) {
    navigator.share({ title: 'ملخص سجل الديون', text }).catch(() => {});
  } else {
    navigator.clipboard.writeText(text);
    toast('تم نسخ ملخص الديون إلى الحافظة 📋');
  }
}

function openMoreOptionsMenu() {
  const m = openModal({
    title: '⚙️ خيارات سجل الديون',
    cls: 'sm',
    body: `
      <div style="display:flex;flex-direction:column;gap:8px">
        <button class="btn ghost" id="menu-opt-new-acc" style="justify-content:flex-start;padding:12px;font-size:15px">
          <span>➕</span>
          <span style="margin-right:8px">إضافة حساب جديد</span>
        </button>

        <button class="btn ghost" id="menu-opt-new-tx" style="justify-content:flex-start;padding:12px;font-size:15px">
          <span>📝</span>
          <span style="margin-right:8px">تسجيل عملية مالية جديدة</span>
        </button>

        <button class="btn ghost" id="menu-opt-charts" style="justify-content:flex-start;padding:12px;font-size:15px">
          <span>📊</span>
          <span style="margin-right:8px">عرض لوحة الرسوم البيانية والإحصائيات</span>
        </button>

        <hr style="border:none;border-top:1px solid var(--border);margin:4px 0" />

        <div style="font-weight:700;font-size:13px;color:var(--text2);margin-top:4px">ترتيب الحسابات:</div>
        <button class="btn ${currentSort === 'default' ? 'primary' : 'ghost'} sm" data-sort="default">الترتيب الافتراضي</button>
        <button class="btn ${currentSort === 'name' ? 'primary' : 'ghost'} sm" data-sort="name">أبجدياً بالاسم (أ-ي)</button>
        <button class="btn ${currentSort === 'balDesc' ? 'primary' : 'ghost'} sm" data-sort="balDesc">الأعلى رصيداً (عليه أولاً)</button>
        <button class="btn ${currentSort === 'balAsc' ? 'primary' : 'ghost'} sm" data-sort="balAsc">الأدنى رصيداً (له أولاً)</button>
        <button class="btn ${currentSort === 'ops' ? 'primary' : 'ghost'} sm" data-sort="ops">الأكثر نشاطاً بعدد العمليات</button>
      </div>
    `,
    foot: `<button class="btn ghost" data-close>إغلاق</button>`
  });

  $('#menu-opt-new-acc', m.overlay).onclick = () => {
    m.close();
    go('accounts', { new: 1 });
  };

  $('#menu-opt-new-tx', m.overlay).onclick = () => {
    m.close();
    go('transactions', { new: 1 });
  };

  $('#menu-opt-charts', m.overlay).onclick = () => {
    m.close();
    viewMode = 'analytics';
    const c = $('#view');
    if (c) render(c, {}, {});
  };

  m.overlay.onclick = (e) => {
    const sBtn = e.target.closest('[data-sort]');
    if (sBtn) {
      currentSort = sBtn.dataset.sort;
      m.close();
      const c = $('#view');
      if (c) render(c, {}, {});
    }
  };
}

function openQuickCreateMenu() {
  const m = openModal({
    title: '⚡ إجراء سريع',
    cls: 'sm',
    body: `
      <div style="display:flex;flex-direction:column;gap:10px">
        <button class="btn primary" id="quick-create-tx" style="padding:14px;font-size:16px;justify-content:center">
          <span>📝 تسجيل عملية مالية جديدة</span>
        </button>
        <button class="btn soft" id="quick-create-acc" style="padding:14px;font-size:16px;justify-content:center">
          <span>➕ إضافة حساب جديد</span>
        </button>
        <button class="btn ghost" id="quick-create-sale" style="padding:14px;font-size:16px;justify-content:center">
          <span>🛒 فاتورة مبيعات جديدة (POS)</span>
        </button>
      </div>
    `,
    foot: `<button class="btn ghost" data-close>إلغاء</button>`
  });

  $('#quick-create-tx', m.overlay).onclick = () => {
    m.close();
    go('transactions', { new: 1 });
  };

  $('#quick-create-acc', m.overlay).onclick = () => {
    m.close();
    go('accounts', { new: 1 });
  };

  $('#quick-create-sale', m.overlay).onclick = () => {
    m.close();
    go('pos');
  };
}

// عرض شاشة الرسوم البيانية والإحصائيات المالية
function renderAnalyticsView(container, settings, txs, accounts, currs) {
  let revenue = 0, expense = 0;
  for (const t of txs) {
    if (t.currency !== settings.defaultCurrency) continue;
    if (t.type === 'revenue' || t.type === 'in') revenue += Math.abs(t.amount);
    else if (t.type === 'expense' || t.type === 'out') expense += Math.abs(t.amount);
  }

  const daily = lastDays(7, txs, settings.defaultCurrency);
  const monthly = lastMonths(6, txs, settings.defaultCurrency);

  container.innerHTML = `
    <div class="page-header" style="display:flex;justify-content:space-between;align-items:center">
      <div>
        <h1 class="page-title">لوحة الرسوم البيانية والإحصائيات 📊</h1>
        <p class="page-sub">تحليل التدفق المالي وحركة الحسابات</p>
      </div>
      <button class="btn primary" id="btn-back-to-ledger">🔙 العودة إلى سجل الديون</button>
    </div>

    <div class="stats-grid">
      <div class="stat-card">
        <div class="stat-label">المقبوضات والإيرادات</div>
        <div class="stat-val green">${fmt(revenue)}</div>
      </div>
      <div class="stat-card">
        <div class="stat-label">المدفوعات والمصروفات</div>
        <div class="stat-val red">${fmt(expense)}</div>
      </div>
      <div class="stat-card">
        <div class="stat-label">عدد الحسابات</div>
        <div class="stat-val">${accounts.length}</div>
      </div>
      <div class="stat-card">
        <div class="stat-label">إجمالي العمليات</div>
        <div class="stat-val">${txs.length}</div>
      </div>
    </div>

    <div class="grid-2">
      <div class="card">
        <div class="card-head">
          <div class="card-title">حركة النقدية — آخر 7 أيام</div>
        </div>
        <div class="chart-bars">${renderBars(daily)}</div>
      </div>

      <div class="card">
        <div class="card-head">
          <div class="card-title">حجم العمليات الشهري</div>
        </div>
        <div class="chart-bars">${renderMonthBars(monthly)}</div>
      </div>
    </div>
  `;

  $('#btn-back-to-ledger', container).onclick = () => {
    viewMode = 'ledger';
    render(container, {}, {});
  };
}

function lastDays(n, txs, cur) {
  const days = [];
  for (let i = n - 1; i >= 0; i--) {
    const d = new Date(); d.setDate(d.getDate() - i);
    const key = d.toISOString().slice(0, 10);
    const label = d.toLocaleDateString('ar-EG-u-ca-gregory-nu-latn', { weekday: 'short' });
    let up = 0, down = 0;
    for (const t of txs) {
      if (t.currency !== cur) continue;
      if (t.date !== key) continue;
      const g = t.type === 'revenue' || t.type === 'in' ? 'up' : t.type === 'expense' || t.type === 'out' ? 'down' : null;
      if (g === 'up') up += Math.abs(t.amount);
      else if (g === 'down') down += Math.abs(t.amount);
    }
    days.push({ label, up, down });
  }
  return days;
}

function lastMonths(n, txs, cur) {
  const months = [];
  const now = new Date();
  for (let i = n - 1; i >= 0; i--) {
    const d = new Date(now.getFullYear(), now.getMonth() - i, 1);
    const key = d.getFullYear() + '-' + String(d.getMonth() + 1).padStart(2, '0');
    let up = 0, down = 0;
    for (const t of txs) {
      if (t.currency !== cur) continue;
      if (!t.date) continue;
      const tk = t.date.slice(0, 7);
      if (tk !== key) continue;
      const g = t.type === 'revenue' || t.type === 'in' ? 'up' : t.type === 'expense' || t.type === 'out' ? 'down' : null;
      if (g === 'up') up += Math.abs(t.amount);
      else if (g === 'down') down += Math.abs(t.amount);
    }
    months.push({ label: d.toLocaleDateString('ar-EG-u-ca-gregory-nu-latn', { month: 'short' }), up, down });
  }
  return months;
}

function renderBars(daily) {
  const max = Math.max(1, ...daily.map(d => Math.max(d.up, d.down)));
  return daily.map(d => `
    <div class="bar-col" title="${esc(d.label)}: قبض ${fmt(d.up)} / صرف ${fmt(d.down)}">
      <div class="bar up" style="height:${Math.round(d.up / max * 100)}%"></div>
      <div class="bar down" style="height:${Math.round(d.down / max * 100)}%"></div>
      <span class="bar-label">${esc(d.label)}</span>
    </div>`).join('');
}

function renderMonthBars(monthly) {
  const max = Math.max(1, ...monthly.map(d => Math.max(d.up, d.down)));
  return dailyBarMonthly(monthly, max);
}

function dailyBarMonthly(monthly, max) {
  return monthly.map(d => `
    <div class="bar-col" title="${esc(d.label)}">
      <div class="bar primary" style="height:${Math.round(Math.max(d.up, d.down) / max * 100)}%"></div>
      <span class="bar-label">${esc(d.label)}</span>
    </div>`).join('');
}
