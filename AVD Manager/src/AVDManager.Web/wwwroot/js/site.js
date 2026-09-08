(() => {
  const root = document.documentElement;
  const savedTheme = localStorage.getItem('avd-manager-theme') || 'dark';
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
})();
