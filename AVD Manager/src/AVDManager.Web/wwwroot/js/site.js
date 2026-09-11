(() => {
  const root = document.documentElement;
  const savedTheme = localStorage.getItem('avd-manager-theme') || 'dark';
  const liveUpdateKey = 'avd-manager-live-update';
  root.dataset.theme = savedTheme;

  const toggle = document.getElementById('themeToggle');
  const refreshThemeUi = () => {
    if (toggle) toggle.textContent = root.dataset.theme === 'dark' ? '☾' : '☀';
    document.querySelectorAll('[data-set-theme]').forEach(button => {
      button.classList.toggle('selected', button.dataset.setTheme === root.dataset.theme);
    });
  };

  const setTheme = theme => {
    root.dataset.theme = theme;
    localStorage.setItem('avd-manager-theme', theme);
    refreshThemeUi();
  };

  refreshThemeUi();
  toggle?.addEventListener('click', () => setTheme(root.dataset.theme === 'dark' ? 'light' : 'dark'));
  document.querySelectorAll('[data-set-theme]').forEach(button => button.addEventListener('click', () => setTheme(button.dataset.setTheme)));

  const liveUpdateToggle = document.querySelector('[data-live-update-toggle]');
  const liveUpdateEnabled = () => localStorage.getItem(liveUpdateKey) !== 'off';
  const refreshLiveUpdateUi = () => {
    if (liveUpdateToggle) liveUpdateToggle.checked = liveUpdateEnabled();
  };
  refreshLiveUpdateUi();
  liveUpdateToggle?.addEventListener('change', () => {
    localStorage.setItem(liveUpdateKey, liveUpdateToggle.checked ? 'on' : 'off');
    refreshLiveUpdateUi();
  });

  // Refresh read-only page state every 30 seconds. Avoid refreshing while the user
  // is editing a form so deployment/settings input is never discarded.
  let formDirty = false;
  document.querySelectorAll('form').forEach(form => {
    form.addEventListener('input', () => { formDirty = true; });
    form.addEventListener('change', () => { formDirty = true; });
    form.addEventListener('submit', () => { formDirty = false; });
  });
  window.setInterval(() => {
    if (!liveUpdateEnabled() || document.hidden || formDirty) return;
    window.location.reload();
  }, 30000);

  const infoToggle = document.getElementById('infoToggle');
  const infoPanel = document.getElementById('infoPanel');
  const infoClose = document.getElementById('infoClose');

  const setInfoOpen = open => {
    if (!infoPanel || !infoToggle) return;
    infoPanel.hidden = !open;
    infoToggle.setAttribute('aria-expanded', open ? 'true' : 'false');
  };

  infoToggle?.addEventListener('click', event => {
    event.stopPropagation();
    setInfoOpen(infoPanel?.hidden ?? true);
  });
  infoClose?.addEventListener('click', () => setInfoOpen(false));
  infoPanel?.addEventListener('click', event => event.stopPropagation());
  document.addEventListener('click', () => setInfoOpen(false));
  document.addEventListener('keydown', event => {
    if (event.key === 'Escape') setInfoOpen(false);
  });

  document.querySelectorAll('form[data-progress-label]').forEach(form => {
    form.addEventListener('submit', event => {
      if (event.defaultPrevented) return;
      const progress = document.getElementById('operationProgress');
      const progressText = document.getElementById('operationProgressText');
      const progressCount = document.getElementById('operationProgressCount');
      if (!progress || !progressText || !progressCount) return;

      progressText.textContent = form.dataset.progressLabel || 'Working…';
      progressCount.textContent = '';
      progress.hidden = false;
      progress.classList.remove('is-complete');
      progress.classList.add('is-indeterminate');
      document.querySelector('.top-status-message')?.remove();
      form.querySelectorAll('button, input[type="submit"]').forEach(control => control.disabled = true);
    });
  });
})();
