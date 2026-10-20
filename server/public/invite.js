'use strict';
const match = location.pathname.match(/^\/party\/([a-f0-9]{32}|[\w-]{12})$/);
const token = location.hash.slice(1);
const status = document.getElementById('status');
if (match) {
  document.getElementById('eyebrow').textContent = 'YOU’RE INVITED';
  document.getElementById('headline').textContent = 'Good music. Better company.';
  document.getElementById('description').textContent = 'Someone saved you a place in their Party Session. Open gaze to join their soundtrack, wherever you are.';
  if (match[1].length === 12 || /^[\w-]{43}$/.test(token)) {
    const link = document.getElementById('open');
    // Use only this site's origin when opening the desktop app.
    link.href = `gaze://party/${match[1]}?server=${encodeURIComponent(location.origin)}${token ? '#' + token : ''}`;
    link.textContent = 'Open in gaze ↗';
    link.addEventListener('click', () => {
      status.textContent = 'Allow your browser to open gaze. If nothing happens, install gaze, then open this invitation again. You can also paste this link into gaze’s Party Session dialog.';
    });
    document.getElementById('hint').textContent = 'New here? Download gaze, then return to this invite.';
  } else {
    status.textContent = 'This invitation is incomplete. Ask your friend to copy a fresh invite from gaze.';
  }
}
