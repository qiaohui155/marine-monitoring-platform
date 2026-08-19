(function () {
  'use strict';

  class FloatingPanelManager {
    constructor(options = {}) {
      this.headerHeight = options.headerHeight || 60;
      this.margin = options.margin || 12;
      this.highestZIndex = options.startingZIndex || 1100;
      this.panels = new Map();
      this.dragState = null;
      this.boundMove = event => this.onPointerMove(event);
      this.boundEnd = event => this.onPointerEnd(event);
    }

    init() {
      document.querySelectorAll('[data-floating-panel]').forEach((element, index) => {
        const id = element.dataset.floatingPanel;
        const state = {
          id,
          element,
          visible: false,
          minimized: false,
          x: this.numberValue(element.dataset.defaultX, 76 + index * 18),
          y: this.numberValue(element.dataset.defaultY, this.headerHeight + 62 + index * 16),
          defaultX: this.numberValue(element.dataset.defaultX, 76 + index * 18),
          defaultY: this.numberValue(element.dataset.defaultY, this.headerHeight + 62 + index * 16),
          centerOnFirstOpen: element.dataset.centered === 'true',
          hasOpened: false,
          zIndex: this.highestZIndex + index
        };

        this.panels.set(id, state);
        this.applyPosition(state);
        this.setVisible(state, false);

        element.addEventListener('pointerdown', () => this.bringToFront(id));
        element.querySelector('[data-drag-handle]')?.addEventListener('pointerdown', event => {
          this.startDrag(id, event);
        });
        element.querySelector('[data-panel-minimize]')?.addEventListener('click', event => {
          event.stopPropagation();
          this.toggleMinimized(id);
        });
        element.querySelector('[data-panel-hide]')?.addEventListener('click', event => {
          event.stopPropagation();
          this.hide(id);
        });
        element.querySelector('[data-panel-close]')?.addEventListener('click', event => {
          event.stopPropagation();
          this.close(id);
        });
      });

      document.querySelectorAll('[data-panel-target]').forEach(button => {
        button.addEventListener('click', () => this.open(button.dataset.panelTarget));
      });

      window.addEventListener('resize', () => this.keepPanelsInViewport());
      document.addEventListener('keydown', event => {
        if (event.key === 'Escape') this.hideTopPanel();
      });
      this.syncToolbar();
      return this;
    }

    numberValue(value, fallback) {
      const number = Number(value);
      return Number.isFinite(number) ? number : fallback;
    }

    get(id) {
      return this.panels.get(id) || null;
    }

    open(id) {
      const state = this.get(id);
      if (!state) return;
      this.setVisible(state, true);
      this.bringToFront(id);
      if (state.centerOnFirstOpen && !state.hasOpened) this.centerPanel(state);
      this.clampPosition(state);
      this.applyPosition(state);
      state.hasOpened = true;
      state.element.querySelector('button, input, select, [tabindex]')?.focus({ preventScroll: true });
      this.syncToolbar();
    }

    hide(id) {
      const state = this.get(id);
      if (!state) return;
      this.setVisible(state, false);
      this.syncToolbar();
    }

    close(id) {
      const state = this.get(id);
      if (!state) return;
      state.minimized = false;
      state.element.classList.remove('is-minimized');
      this.setVisible(state, false);
      this.syncToolbar();
    }

    hideAll() {
      this.panels.forEach(state => this.setVisible(state, false));
      this.syncToolbar();
    }

    hideTopPanel() {
      const topPanel = [...this.panels.values()]
        .filter(state => state.visible)
        .sort((a, b) => b.zIndex - a.zIndex)[0];
      if (topPanel) this.hide(topPanel.id);
    }

    toggleMinimized(id) {
      const state = this.get(id);
      if (!state) return;
      state.minimized = !state.minimized;
      state.element.classList.toggle('is-minimized', state.minimized);
      state.element.querySelector('[data-panel-minimize]')?.setAttribute(
        'aria-label',
        state.minimized ? 'Restore panel' : 'Minimize panel'
      );
      this.bringToFront(id);
      this.clampPosition(state);
      this.applyPosition(state);
    }

    bringToFront(id) {
      const state = this.get(id);
      if (!state) return;
      this.highestZIndex += 1;
      state.zIndex = this.highestZIndex;
      state.element.style.zIndex = String(state.zIndex);
      this.panels.forEach(panel => {
        panel.element.classList.toggle('is-active', panel.id === id && panel.visible);
      });
    }

    setVisible(state, visible) {
      state.visible = visible;
      state.element.classList.toggle('is-visible', visible);
      state.element.setAttribute('aria-hidden', String(!visible));
      state.element.inert = !visible;
    }

    startDrag(id, event) {
      if (event.button !== 0 || event.target.closest('button, input, select, textarea, a')) return;
      const state = this.get(id);
      if (!state || !state.visible) return;

      const rect = state.element.getBoundingClientRect();
      this.dragState = {
        id,
        pointerId: event.pointerId,
        offsetX: event.clientX - rect.left,
        offsetY: event.clientY - rect.top
      };

      this.bringToFront(id);
      state.element.classList.add('is-dragging');
      event.currentTarget.setPointerCapture?.(event.pointerId);
      document.body.classList.add('panel-dragging');
      document.addEventListener('pointermove', this.boundMove, { passive: false });
      document.addEventListener('pointerup', this.boundEnd);
      document.addEventListener('pointercancel', this.boundEnd);
      event.preventDefault();
      event.stopPropagation();
    }

    onPointerMove(event) {
      if (!this.dragState || event.pointerId !== this.dragState.pointerId) return;
      const state = this.get(this.dragState.id);
      if (!state) return;
      state.x = event.clientX - this.dragState.offsetX;
      state.y = event.clientY - this.dragState.offsetY;
      this.clampPosition(state);
      this.applyPosition(state);
      event.preventDefault();
      event.stopPropagation();
    }

    onPointerEnd(event) {
      if (!this.dragState || event.pointerId !== this.dragState.pointerId) return;
      const state = this.get(this.dragState.id);
      state?.element.classList.remove('is-dragging');
      this.dragState = null;
      document.body.classList.remove('panel-dragging');
      document.removeEventListener('pointermove', this.boundMove);
      document.removeEventListener('pointerup', this.boundEnd);
      document.removeEventListener('pointercancel', this.boundEnd);
    }

    clampPosition(state) {
      const rect = state.element.getBoundingClientRect();
      const width = Math.min(rect.width || 340, window.innerWidth - this.margin * 2);
      const height = Math.min(rect.height || 180, window.innerHeight - this.headerHeight - this.margin * 2);
      const maxX = Math.max(this.margin, window.innerWidth - width - this.margin);
      const maxY = Math.max(this.headerHeight + this.margin, window.innerHeight - height - this.margin);
      state.x = Math.min(Math.max(state.x, this.margin), maxX);
      state.y = Math.min(Math.max(state.y, this.headerHeight + this.margin), maxY);
    }

    centerPanel(state) {
      const width = state.element.offsetWidth || 680;
      const height = state.element.offsetHeight || 460;
      state.x = (window.innerWidth - width) / 2;
      state.y = this.headerHeight + (window.innerHeight - this.headerHeight - height) / 2;
    }

    applyPosition(state) {
      state.element.style.left = `${Math.round(state.x)}px`;
      state.element.style.top = `${Math.round(state.y)}px`;
      state.element.style.zIndex = String(state.zIndex);
    }

    keepPanelsInViewport() {
      this.panels.forEach(state => {
        if (!state.visible) return;
        this.clampPosition(state);
        this.applyPosition(state);
      });
    }

    syncToolbar() {
      document.querySelectorAll('[data-panel-target]').forEach(button => {
        const state = this.get(button.dataset.panelTarget);
        const visible = Boolean(state?.visible);
        button.classList.toggle('is-active', visible);
        button.setAttribute('aria-pressed', String(visible));
      });
    }
  }

  window.FloatingPanelManager = FloatingPanelManager;
})();
