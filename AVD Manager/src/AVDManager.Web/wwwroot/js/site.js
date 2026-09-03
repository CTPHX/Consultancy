(() => {
  const root = document.documentElement;
  const savedTheme = localStorage.getItem('avd-manager-theme') || 'dark';
  root.dataset.theme = savedTheme;

  const toggle = document.getElementById('themeToggle');
  const refreshIcon = () => { if (toggle) toggle.textContent = root.dataset.theme === 'dark' ? '☾' : '☀'; };
  refreshIcon();

  toggle?.addEventListener('click', () => {
    root.dataset.theme = root.dataset.theme === 'dark' ? 'light' : 'dark';
    localStorage.setItem('avd-manager-theme', root.dataset.theme);
    refreshIcon();
  });
})();
