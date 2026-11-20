/**
 * dsh-stealth — Client half.
 *
 * One master switch rendered natively in the DSH Settings shell (nav entry
 * "隐身模式"): ON hides the external traces — taskbar button and Alt-Tab
 * entry via WS_EX_TOOLWINDOW, plus the (already transparent) tray badge —
 * while the window stays fully usable; OFF restores all of it. No window is
 * ever hidden, so no hotkey listener is needed.
 *
 * The switch follows the settings-shell recipe from the better-sidebar
 * reference: a real checkbox (native semantics and focus) driving a styled
 * track/thumb, inside a PluginCard-style section card (12px radius, l2
 * hairline, section heading + one-line intro).
 *
 * @module dsh-stealth/client
 */
window.__ModuleLoader__.load({
  id: 'dsh-stealth',
  factory: (require) => {
    var React = require('react');

    var NS = 'dshStealth';
    var DICT = {
      zh: {
        settingsNav: '隐身模式',
        sectionTitle: '隐身模式',
        sectionIntro: '隐藏 DeepSeek Harness 的外部痕迹：任务栏按钮、Alt-Tab 与托盘角标。窗口保持正常可用。',
        rowTitle: '隐藏任务栏图标与托盘角标',
        rowDesc: '开启后任务栏按钮和 Alt-Tab 项立即消失，窗口照常使用；应用重启后仍保持。关闭即全部恢复。（任务管理器的后台进程行属于系统账本，不做隐藏。）',
        switchOn: '已开启 — 任务栏与角标已隐藏',
        switchOff: '已关闭 — 图标正常显示',
        stateError: '状态获取失败，请重启应用'
      },
      en: {
        settingsNav: 'Stealth Mode',
        sectionTitle: 'Stealth Mode',
        sectionIntro: 'Hide the external traces of DeepSeek Harness: taskbar button, Alt-Tab and the tray badge. The window stays fully usable.',
        rowTitle: 'Hide taskbar button and tray badge',
        rowDesc: 'While on, the taskbar button and Alt-Tab entry disappear immediately and the window keeps working; the state survives app restarts. Turn off to restore everything. (The Task Manager background row is the system ledger and stays.)',
        switchOn: 'On — taskbar and badge hidden',
        switchOff: 'Off — icons visible',
        stateError: 'State unavailable, please restart the app'
      }
    };

    var translate = null;
    function tr(key, params) {
      if (translate !== null) return translate(key, params);
      return key;
    }

    function config() {
      var injected = globalThis.__DSH_STEALTH__;
      return injected !== undefined && injected !== null
        ? injected
        : { routePath: '/api/dsh-stealth' };
    }

    /** Shared reading of the Host's observable state, polled while mounted. */
    var store = {
      state: null,
      pending: false,
      watchers: [],
      timer: null
    };

    function notifyWatchers() {
      for (var index = 0; index < store.watchers.length; index += 1) store.watchers[index]();
    }

    function refresh() {
      if (store.pending) return Promise.resolve();
      store.pending = true;
      return fetch(config().routePath + '?op=state', { cache: 'no-store' })
        .then(function (response) { return response.ok ? response.json() : null; })
        .then(function (body) {
          if (body !== null && typeof body === 'object' && body.ok === true) {
            store.state = body;
            notifyWatchers();
          }
        })
        .catch(function () {})
        .then(function () { store.pending = false; });
    }

    function act(op) {
      store.failed = false;
      return fetch(config().routePath + '?op=' + op, { method: 'POST', cache: 'no-store' })
        .then(function (response) { return response.ok ? response.json() : null; })
        .then(function (body) {
          store.pending = false;
          return refresh();
        })
        .catch(function () { return null; });
    }

    function useStealthState() {
      var pair = React.useState(store.state);
      var setState = pair[1];
      React.useEffect(function () {
        var watcher = function () { setState(store.state); };
        store.watchers.push(watcher);
        refresh();
        if (store.timer === null) {
          store.timer = setInterval(function () {
            if (typeof document === 'undefined' || document.hidden !== true) refresh();
          }, 8000);
        }
        return function () {
          var at = store.watchers.indexOf(watcher);
          if (at >= 0) store.watchers.splice(at, 1);
          if (store.watchers.length === 0 && store.timer !== null) {
            clearInterval(store.timer);
            store.timer = null;
          }
        };
      }, [setState]);
      return pair[0];
    }

    /* — styles (settings-shell recipe, inline so no CSS module is needed) — */

    var CARD = {
      display: 'flex',
      flexDirection: 'column',
      gap: '8px',
      padding: '16px',
      borderRadius: '12px',
      border: '1px solid var(--dsw-alias-border-l2)',
      background: 'var(--dsw-alias-bg-layer-2)',
      margin: '0 0 16px 0'
    };
    var HEADING = {
      font: 'inherit',
      fontSize: '14px',
      fontWeight: 600,
      color: 'var(--dsw-alias-label-primary)',
      margin: 0
    };
    var INTRO = {
      fontSize: '12px',
      lineHeight: '18px',
      color: 'var(--dsw-alias-label-secondary)'
    };
    var ROW = {
      display: 'flex',
      alignItems: 'center',
      justifyContent: 'space-between',
      gap: '16px',
      padding: '12px 0 0 0',
      borderTop: '1px solid var(--dsw-alias-border-l2)'
    };
    var ROW_TITLE = {
      fontSize: '13px',
      color: 'var(--dsw-alias-label-primary)'
    };
    var ROW_DESC = {
      fontSize: '12px',
      lineHeight: '18px',
      color: 'var(--dsw-alias-label-secondary)',
      marginTop: '2px',
      maxWidth: '560px'
    };
    var SWITCH_BOX = {
      position: 'relative',
      display: 'inline-flex',
      flex: 'none',
      cursor: 'pointer'
    };
    var SWITCH_INPUT = {
      position: 'absolute',
      width: '1px',
      height: '1px',
      margin: '0',
      opacity: '0'
    };

    function trackStyle(checked) {
      return {
        display: 'inline-flex',
        alignItems: 'center',
        width: '36px',
        height: '20px',
        padding: '2px',
        boxSizing: 'border-box',
        borderRadius: '10px',
        border: '1px solid ' + (checked ? 'var(--dsw-alias-button-primary-fill)' : 'var(--dsw-alias-border-l2)'),
        background: checked ? 'var(--dsw-alias-button-primary-fill)' : 'var(--dsw-alias-bg-layer-2)',
        transition: 'background 0.15s ease, border-color 0.15s ease'
      };
    }

    function thumbStyle(checked) {
      return {
        display: 'block',
        width: '14px',
        height: '14px',
        borderRadius: '50%',
        background: checked ? 'var(--dsw-alias-bg-layer-3)' : 'var(--dsw-alias-label-tertiary)',
        transform: checked ? 'translateX(16px)' : 'translateX(0)',
        transition: 'transform 0.15s ease, background 0.15s ease'
      };
    }

    /** Eye-off glyph for the settings nav (lucide eye-off path). */
    var ICON_SVG = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" width="{size}" height="{size}"><path d="M9.88 9.88a3 3 0 1 0 4.24 4.24"/><path d="M10.73 5.08A10.43 10.43 0 0 1 12 5c7 0 10 7 10 7a13.16 13.16 0 0 1-1.67 2.68"/><path d="M6.61 6.61A13.526 13.526 0 0 0 2 12s3 7 10 7a9.74 9.74 0 0 0 5.39-1.61"/><line x1="2" x2="22" y1="2" y2="22"/></svg>';

    function NavIcon(props) {
      var size = props !== null && props !== undefined && typeof props.size === 'number' ? props.size : 20;
      return React.createElement('span', {
        style: { display: 'inline-flex', color: 'inherit' },
        dangerouslySetInnerHTML: { __html: ICON_SVG.replace(/\{size\}/g, String(size)) }
      });
    }

    function Switch(props) {
      return React.createElement('label', { style: SWITCH_BOX, title: props.title },
        React.createElement('input', {
          type: 'checkbox',
          checked: props.checked === true,
          onChange: props.onChange,
          style: SWITCH_INPUT
        }),
        React.createElement('span', { style: trackStyle(props.checked === true) },
          React.createElement('span', { style: thumbStyle(props.checked === true) })
        )
      );
    }

    function StealthSection() {
      var state = useStealthState();
      var stealth = state !== null && state.stealth === true;
      var statusText = state === null ? tr('stateError') : (stealth ? tr('switchOn') : tr('switchOff'));
      return React.createElement('div', { 'data-dsh-stealth-section': true, style: CARD },
        React.createElement('h3', { style: HEADING }, tr('sectionTitle')),
        React.createElement('div', { style: INTRO }, tr('sectionIntro')),
        React.createElement('div', { style: ROW },
          React.createElement('div', { style: { minWidth: '0' } },
            React.createElement('div', { style: ROW_TITLE }, statusText),
            React.createElement('div', { style: ROW_DESC }, tr('rowDesc'))
          ),
          React.createElement(Switch, {
            checked: stealth,
            title: tr('rowTitle'),
            onChange: function () { act('toggle'); }
          })
        )
      );
    }

    return {
      inject: ['slots', 'locale'],
      apply: function (ctx) {
        ctx.effect(function () {
          return ctx.locale.register(NS, {
            zh: DICT.zh,
            en: DICT.en,
            ja: DICT.en,
            es: DICT.en,
            fr: DICT.en,
            de: DICT.en,
            ru: DICT.en,
            pt: DICT.en
          });
        });
        translate = ctx.locale.bind(NS);
        // Settings shell: one nav entry (with icon) + one section card with
        // the master switch. Order 100 puts it after the built-in sections.
        ctx.effect(function () {
          return ctx.slots.inject('settings.section', function () {
            return ctx.slots.register({
              name: 'settings.section',
              id: 'dsh-stealth',
              order: 100,
              label: function () { return tr('settingsNav'); }
            }, StealthSection);
          });
        });
        ctx.effect(function () {
          return ctx.slots.inject('settings.section.icon', function () {
            return ctx.slots.register({
              name: 'settings.section.icon',
              id: 'dsh-stealth',
              order: 100,
              label: function () { return tr('settingsNav'); }
            }, NavIcon);
          });
        });
      }
    };
  }
});
