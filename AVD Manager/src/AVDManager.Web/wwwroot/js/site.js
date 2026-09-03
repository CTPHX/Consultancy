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
})();
