// Popovers use trigger:"manual" because Bootstrap's built-in "hover" trigger
// hides the popover the instant the cursor leaves the icon - too fast to
// reach the "Learn more" link inside it. Instead we track hover over both
// the icon and the popover's own tip element, with a short delay before
// hiding, so the cursor can travel from one to the other.
var helpHideTimers = new WeakMap();

function cancelHelpHide(el) {
  var timer = helpHideTimers.get(el);
  if (timer) {
    clearTimeout(timer);
    helpHideTimers.delete(el);
  }
}

function scheduleHelpHide(el) {
  cancelHelpHide(el);
  helpHideTimers.set(el, setTimeout(function () {
    var instance = bootstrap.Popover.getInstance(el);
    if (instance) instance.hide();
  }, 250));
}

function initHelpPopovers(root) {
  root.querySelectorAll('[data-bs-toggle="popover"]').forEach(function (el) {
    if (bootstrap.Popover.getInstance(el)) return;
    // sanitize:false must be set here (not via a data-bs-sanitize attribute)
    // because Bootstrap reads data attributes as strings, and the string
    // "false" is truthy in JS - sanitization would otherwise stay enabled
    // and silently strip the data-manual-anchor attribute off the link.
    var popover = new bootstrap.Popover(el, { sanitize: false });

    el.addEventListener('mouseenter', function () {
      cancelHelpHide(el);
      popover.show();
    });
    el.addEventListener('mouseleave', function () {
      scheduleHelpHide(el);
    });
    el.addEventListener('focus', function () {
      cancelHelpHide(el);
      popover.show();
    });
    el.addEventListener('blur', function () {
      scheduleHelpHide(el);
    });

    el.addEventListener('shown.bs.popover', function () {
      var tip = document.getElementById(el.getAttribute('aria-describedby'));
      if (!tip) return;
      tip.addEventListener('mouseenter', function () { cancelHelpHide(el); });
      tip.addEventListener('mouseleave', function () { scheduleHelpHide(el); });
    });
  });
}

document.addEventListener('DOMContentLoaded', function () {
  initHelpPopovers(document);

  // Bootstrap appends popover markup to <body>, outside the triggering
  // element's subtree, so the "Learn more" click listener must be delegated.
  document.body.addEventListener('click', function (e) {
    var link = e.target.closest('.help-learn-more');
    if (!link) return;
    e.preventDefault();
    Shiny.setInputValue(
      'manual_jump_anchor',
      { anchor: link.getAttribute('data-manual-anchor'), nonce: Date.now() },
      { priority: 'event' }
    );
  });
});

// Re-init for any help icons that show up inside dynamically rendered UI.
$(document).on('shiny:value', function (e) {
  initHelpPopovers(e.target);
});

// The Manual tab's content is a suspended-while-hidden Shiny output, so the
// first time it's switched to, output$manual_content only starts rendering
// the markdown *after* it becomes visible - the anchor element doesn't exist
// yet when this message arrives. Keep polling for it (covers that first,
// slower render) but also rescan as soon as that output's "shiny:value"
// fires (covers it landing mid-poll, no need to wait out the interval).
var pendingManualAnchor = null;

function tryScrollToManualAnchor() {
  if (!pendingManualAnchor) return false;
  var el = document.getElementById(pendingManualAnchor);
  if (!el) return false;
  el.scrollIntoView({ behavior: 'smooth', block: 'start' });
  pendingManualAnchor = null;
  return true;
}

Shiny.addCustomMessageHandler('scrollToManualAnchor', function (anchor) {
  pendingManualAnchor = anchor;
  var tries = 0;
  (function poll() {
    if (tryScrollToManualAnchor()) return;
    if (tries++ < 100) setTimeout(poll, 100);
  })();
});

$(document).on('shiny:value', function (e) {
  if (e.target && e.target.id === 'manual_content') tryScrollToManualAnchor();
});
