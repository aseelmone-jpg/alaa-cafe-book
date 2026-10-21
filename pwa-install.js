(() => {
  'use strict';
  const button = document.getElementById('installCafeApp');
  const help = document.getElementById('installCafeHelp');
  if (!button || !help) return;
  const standalone = window.matchMedia('(display-mode: standalone)');
  const ios = /iPad|iPhone|iPod/.test(navigator.userAgent) || (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);
  let installPrompt = null;
  const update = () => {
    button.hidden = standalone.matches || navigator.standalone === true;
    if (button.hidden) help.hidden = true;
  };
  window.addEventListener('beforeinstallprompt', event => {
    event.preventDefault();
    installPrompt = event;
    update();
  });
  window.addEventListener('appinstalled', () => {
    installPrompt = null;
    button.hidden = true;
    help.hidden = true;
  });
  standalone.addEventListener('change', update);
  button.addEventListener('click', async () => {
    if (installPrompt) {
      const prompt = installPrompt;
      installPrompt = null;
      button.disabled = true;
      try { await prompt.prompt(); await prompt.userChoice; }
      catch { help.textContent = 'Open your browser menu and choose Install app or Add to Home screen.'; help.hidden = false; }
      finally { button.disabled = false; }
      return;
    }
    help.textContent = ios
      ? 'On iPhone or iPad: open this site in Safari, tap Share, then Add to Home Screen. Enable Open as Web App if offered, then tap Add. Internet is required for accounting data.'
      : 'Open your browser menu and choose Install app or Add to Home screen if available. If it is missing, use a supported browser on the HTTPS live site. Internet is required for accounting data.';
    help.hidden = !help.hidden;
  });
  update();
})();
