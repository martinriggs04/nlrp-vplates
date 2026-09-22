/**
 * nlrp-vplates | html/app.js
 * Dependency-free NUI controller.
 *
 * Security notes:
 *  - every value coming from the game is injected with `textContent`,
 *    never `innerHTML`, so a crafted plate can never inject markup.
 *  - the input is sanitised on every keystroke with the same rules the
 *    Lua side enforces (the server still re-validates everything).
 */

const RESOURCE = (typeof GetParentResourceName === 'function')
    ? GetParentResourceName()
    : 'nlrp-vplates';

const $ = (id) => document.getElementById(id);

const post = (endpoint, body = {}) =>
    fetch(`https://${RESOURCE}/${endpoint}`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json; charset=UTF-8' },
        body: JSON.stringify(body),
    }).catch(() => {});

/* ── Toasts ──────────────────────────────────────────────────────────────── */

class ToastStack {
    constructor(root) {
        this.root = root;
        this.max = 4;
    }

    push(ok, message) {
        if (typeof message !== 'string' || !message.length) return;

        const el = document.createElement('div');
        el.className = `toast ${ok ? 'is-ok' : 'is-error'}`;
        el.textContent = message;
        this.root.appendChild(el);

        while (this.root.children.length > this.max) {
            this.root.removeChild(this.root.firstChild);
        }

        setTimeout(() => {
            el.classList.add('is-out');
            setTimeout(() => el.remove(), 220);
        }, 4200);
    }
}

/* ── Progress ────────────────────────────────────────────────────────────── */

class ProgressBar {
    constructor() {
        this.root = $('progress');
        this.fill = $('progress-fill');
        this.label = $('progress-label');
        this.hint = $('progress-hint');
        this.frame = null;
    }

    show(duration, label, hint) {
        this.label.textContent = label || '';
        this.hint.textContent = hint || '';
        this.root.classList.remove('hidden');

        const start = performance.now();
        const step = (now) => {
            const pct = Math.min(100, ((now - start) / duration) * 100);
            this.fill.style.width = `${pct}%`;
            if (pct < 100) this.frame = requestAnimationFrame(step);
        };

        cancelAnimationFrame(this.frame);
        this.fill.style.width = '0%';
        this.frame = requestAnimationFrame(step);
    }

    hide() {
        cancelAnimationFrame(this.frame);
        this.frame = null;
        this.root.classList.add('hidden');
        this.fill.style.width = '0%';
    }
}

/* ── Prompt ──────────────────────────────────────────────────────────────── */

class Prompt {
    constructor() {
        this.root = $('prompt');
        this.key = $('prompt-key');
        this.label = $('prompt-label');
    }

    set(visible, label, key) {
        if (!visible) {
            this.root.classList.add('hidden');
            return;
        }
        this.key.textContent = key || 'E';
        this.label.textContent = label || '';
        this.root.classList.remove('hidden');
    }
}

/* ── Format mask ─────────────────────────────────────────────────────────── */

/**
 * Client side twin of `PlateFormat` (shared/pattern.lua).
 * The player only ever types the editable characters; literal slots are
 * inserted automatically, so a wrong shape simply cannot be produced here.
 * The server still re-validates the composed plate against the same mask.
 */
class FormatMask {
    constructor(spec) {
        this.slots = Array.isArray(spec.slots) ? spec.slots : [];
        this.length = this.slots.length;
        this.mask = String(spec.mask || '');
        this.example = String(spec.example || '');
        this.editableSlots = this.slots.filter((slot) => slot.kind !== 'literal');
        this.editable = this.editableSlots.length;
    }

    static accepts(kind, char) {
        return kind === 'digit' ? char >= '0' && char <= '9' : char >= 'A' && char <= 'Z';
    }

    /** Drops every character that does not fit the next editable slot. */
    filter(raw) {
        const chars = String(raw).toUpperCase().replace(/[^A-Z0-9]/g, '');
        const out = [];

        for (const char of chars) {
            const slot = this.editableSlots[out.length];
            if (!slot) break;
            if (FormatMask.accepts(slot.kind, char)) out.push(char);
        }

        return out.join('');
    }

    compose(typed, placeholder = '_') {
        const chars = String(typed);
        let cursor = 0;
        let complete = true;

        const plate = this.slots.map((slot) => {
            if (slot.kind === 'literal') return slot.char;
            const char = chars[cursor++];
            if (char) return char;
            complete = false;
            return placeholder;
        }).join('');

        return { plate, complete };
    }

    randomize() {
        const digits = '0123456789';
        const letters = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';
        const pick = (set) => set[Math.floor(Math.random() * set.length)];

        return this.editableSlots
            .map((slot) => pick(slot.kind === 'digit' ? digits : letters))
            .join('');
    }

    /** Editable-only view of the example, used as the input placeholder. */
    placeholder() {
        let out = '';
        for (let i = 0; i < this.slots.length; i += 1) {
            if (this.slots[i].kind !== 'literal') out += this.example[i] || '';
        }
        return out;
    }
}

/* ── Dialog ──────────────────────────────────────────────────────────────── */

class PlateDialog {
    constructor(toasts) {
        this.toasts = toasts;
        this.overlay = $('overlay');
        this.input = $('plate-input');
        this.preview = $('plate-preview');
        this.confirm = $('btn-confirm');
        this.cancel = $('btn-cancel');
        this.error = $('error');
        this.random = $('btn-random');
        this.open = false;
        this.config = { minLen: 2, maxLen: 8 };
        this.format = null;
        this.empty = '--';

        this.input.addEventListener('input', () => this.onInput());
        this.confirm.addEventListener('click', () => this.submit());
        this.cancel.addEventListener('click', () => this.dismiss());
        this.random.addEventListener('click', () => this.shuffle());

        this.input.addEventListener('keydown', (e) => {
            if (e.key === 'Enter') { e.preventDefault(); this.submit(); }
        });

        document.addEventListener('keydown', (e) => {
            if (!this.open) return;
            if (e.key === 'Escape') { e.preventDefault(); this.dismiss(); }
        });
    }

    /** Mirrors Utils.Sanitize on the Lua side. */
    sanitize(raw) {
        return String(raw)
            .toUpperCase()
            .replace(/[^A-Z0-9 ]/g, '')
            .replace(/\s+/g, ' ')
            .slice(0, this.config.maxLen)
            .replace(/^\s+|\s+$/g, '');
    }

    show(data) {
        this.config.minLen = Number(data.minLen) || 2;
        this.config.maxLen = Number(data.maxLen) || 8;

        const spec = data.format;
        this.format = (spec && Array.isArray(spec.slots) && spec.slots.length)
            ? new FormatMask(spec)
            : null;

        const s = data.strings || {};
        $('ui-title').textContent = s.title || '';
        $('ui-subtitle').textContent = s.subtitle || '';
        $('lbl-current').textContent = s.current || '';
        $('lbl-new').textContent = s.new || '';
        $('lbl-price').textContent = s.price || '';
        $('hint').textContent = s.hint || '';
        this.confirm.textContent = s.confirm || 'OK';
        this.cancel.textContent = s.cancel || 'Cancel';
        this.random.title = s.randomize || '';

        const badge = $('ui-mode');
        const isFake = data.mode === 'fake';
        badge.textContent = s.badge || '';
        badge.classList.toggle('is-fake', isFake);

        this.empty = s.empty || '--';
        $('plate-current').textContent = data.plate || this.empty;

        const price = Number(data.price) || 0;
        $('price-row').classList.toggle('hidden', isFake || price <= 0);
        $('ui-price').textContent = `$${price.toLocaleString('en-US')}`;

        this.random.classList.toggle('hidden', !this.format);
        this.input.maxLength = this.format ? this.format.editable : this.config.maxLen;
        this.input.placeholder = this.format ? this.format.placeholder() : '';
        this.input.value = '';
        this.preview.textContent = this.format ? this.format.compose('').plate : this.empty;
        this.preview.classList.remove('is-invalid');
        this.error.classList.add('hidden');
        this.confirm.disabled = true;

        this.overlay.classList.remove('hidden');
        this.open = true;
        setTimeout(() => this.input.focus(), 30);
    }

    hide() {
        this.overlay.classList.add('hidden');
        this.open = false;
        this.input.blur();
    }

    onInput() {
        if (this.format) {
            const typed = this.format.filter(this.input.value);
            if (typed !== this.input.value) this.input.value = typed;

            const { plate, complete } = this.format.compose(typed);
            this.preview.textContent = plate;
            this.preview.classList.toggle('is-invalid', !complete && typed.length > 0);
            this.confirm.disabled = !complete;
            return;
        }

        const clean = this.sanitize(this.input.value);
        if (clean !== this.input.value) {
            const pos = this.input.selectionStart;
            this.input.value = clean;
            this.input.setSelectionRange(pos, pos);
        }

        this.preview.textContent = clean.length ? clean : this.empty;

        const valid = clean.replace(/\s/g, '').length >= this.config.minLen;
        this.preview.classList.toggle('is-invalid', clean.length > 0 && !valid);
        this.confirm.disabled = !valid;
    }

    shuffle() {
        if (!this.open || !this.format) return;
        this.input.value = this.format.randomize();
        this.onInput();
        this.input.focus();
    }

    submit() {
        if (!this.open || this.confirm.disabled) return;

        const plate = this.format
            ? this.format.compose(this.input.value).plate
            : this.sanitize(this.input.value);

        this.hide();
        post('vplates:submit', { plate });
    }

    dismiss() {
        if (!this.open) return;
        this.hide();
        post('vplates:cancel');
    }
}

/* ── Wiring ──────────────────────────────────────────────────────────────── */

const toasts = new ToastStack($('toasts'));
const progress = new ProgressBar();
const prompt = new Prompt();
const dialog = new PlateDialog(toasts);

const handlers = {
    open: (data) => dialog.show(data || {}),
    close: () => dialog.hide(),
    notify: (data) => toasts.push(Boolean(data && data.ok), data && data.message),
    prompt: (data) => prompt.set(Boolean(data && data.visible), data && data.label, data && data.key),
    progress: (data) => {
        if (data && data.visible) progress.show(Number(data.duration) || 1000, data.label, data.hint);
        else progress.hide();
    },
};

window.addEventListener('message', (event) => {
    const payload = event.data;
    if (!payload || typeof payload.action !== 'string') return;

    const handler = handlers[payload.action];
    if (handler) handler(payload.data);
});
