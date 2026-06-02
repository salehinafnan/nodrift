/**
 * Utility Functions
 * Contains pure functions separated from DOM for testability.
 */

function formatDuration(sec) {
  if (isNaN(sec)) return "00:00:00";
  // Add a microscopic 1-nanosecond buffer (1e-9) before flooring.
  // This neutralizes IEEE 754 precision drift without causing clock jitter.
  sec = Math.max(0, Math.floor(sec + 1e-9));
  const h = Math.floor(sec / 3600).toString().padStart(2, "0");
  const m = Math.floor((sec % 3600) / 60).toString().padStart(2, "0");
  const s = Math.floor(sec % 60).toString().padStart(2, "0");
  return `${h}:${m}:${s}`;
}

function parseTime(str) {
  if (!str || typeof str !== "string") return null;
  const p = str.trim().split(":");
  let h = 0, m = 0, s = 0;
  if (p.length === 2) {
    h = parseInt(p[0], 10);
    m = parseInt(p[1], 10);
    if (isNaN(h) || isNaN(m) || h < 0 || m < 0) return null;
    return h * 3600 + m * 60;
  } else if (p.length === 3) {
    h = parseInt(p[0], 10);
    m = parseInt(p[1], 10);
    s = parseInt(p[2], 10);
    if (isNaN(h) || isNaN(m) || isNaN(s) || h < 0 || m < 0 || s < 0) return null;
    return h * 3600 + m * 60 + s;
  }
  return null;
}

function formatFriendlyDuration(sec, emptyPlaceholder = '<span style="opacity: 0.25; font-weight: 400;">-</span>') {
  if (sec === undefined || sec === null || sec <= 0) return emptyPlaceholder;
  sec = Math.floor(sec);
  const h = Math.floor(sec / 3600);
  const m = Math.floor((sec % 3600) / 60);
  const s = sec % 60;
  if (h > 0) {
    return m > 0 ? `${h}h ${m}m` : `${h}h`;
  } else {
    if (m > 0) {
      return s > 0 ? `${m}m ${s}s` : `${m}m`;
    } else {
      return s > 0 ? `${s}s` : emptyPlaceholder;
    }
  }
}

function escapeHTML(str) {
  if (!str) return "";
  return String(str).replace(/[&<>'"]/g, (tag) => ({
    "&": "&amp;",
    "<": "&lt;",
    ">": "&gt;",
    "'": "&#39;",
    '"': "&quot;",
  })[tag] || tag);
}

function parseGoalTimeStr(val) {
  let hh = 0;
  let mm = 0;
  const cleanVal = String(val).trim().replace(",", ".");
  if (!cleanVal) return { hh: 8, mm: 0 };
  const naturalMatch = cleanVal.match(/^(?:(\d+(?:\.\d+)?)\s*h)?\s*(?:(\d+)\s*m)?$/i);
  const colonMatch = cleanVal.match(/^(\d+):(\d{1,2})$/);
  const decimalMatch = cleanVal.match(/^(\d+(?:\.\d+))$/);
  if (colonMatch) {
    hh = parseInt(colonMatch[1], 10);
    mm = parseInt(colonMatch[2], 10);
  } else if (decimalMatch) {
    const total = parseFloat(decimalMatch[1]);
    hh = Math.floor(total);
    mm = Math.round((total - hh) * 60);
  } else if (naturalMatch && (naturalMatch[1] || naturalMatch[2])) {
    const rawH = parseFloat(naturalMatch[1] || 0);
    hh = Math.floor(rawH);
    mm = Math.round((rawH - hh) * 60) + parseInt(naturalMatch[2] || 0, 10);
  } else {
    const digits = cleanVal.replace(/\D/g, "");
    if (digits) {
      if (digits.length <= 2) { hh = parseInt(digits, 10) || 0; mm = 0; }
      else if (digits.length === 3) { hh = parseInt(digits.slice(0, 1), 10) || 0; mm = parseInt(digits.slice(1), 10) || 0; }
      else { hh = parseInt(digits.slice(0, 2), 10) || 0; mm = parseInt(digits.slice(2, 4), 10) || 0; }
    } else { hh = 8; }
  }
  hh += Math.floor(mm / 60);
  mm = mm % 60;
  hh = Math.min(24, Math.max(0, hh));
  mm = Math.min(59, Math.max(0, mm));
  return { hh, mm };
}

function getGoalSeconds(h, m) {
  const hVal = Math.max(0, parseFloat(h) || 0);
  const mVal = Math.max(0, parseFloat(m) || 0);
  const total = hVal * 3600 + mVal * 60;
  return total > 0 ? total : 1;
}

function parseTimeToMinutes(timeStr) {
  if (!timeStr || timeStr === "Manual" || timeStr === "Entry" || timeStr === "—" || timeStr === "-") return null;
  const match = String(timeStr).match(/^(\d{2}):(\d{2})\s*(AM|PM)$/i);
  if (!match) return null;
  let hours = parseInt(match[1], 10);
  const minutes = parseInt(match[2], 10);
  const ampm = match[3].toUpperCase();
  if (ampm === "PM" && hours < 12) hours += 12;
  if (ampm === "AM" && hours === 12) hours = 0;
  return hours * 60 + minutes;
}

function debounce(func, wait) {
  let timeout;
  return function (...args) {
    clearTimeout(timeout);
    timeout = setTimeout(() => func.apply(this, args), wait);
  };
}

function hudFuzzyScore(query, target) {
  if (!query || !target) return 0;
  const q = String(query).toLowerCase();
  const t = String(target).toLowerCase();
  
  let qIdx = 0;
  let tIdx = 0;
  let score = 0;
  let consecutive = 0;
  
  while (qIdx < q.length && tIdx < t.length) {
    if (q[qIdx] === t[tIdx]) {
      score += 10;
      score += consecutive * 5; 
      
      if (tIdx === 0 || t[tIdx - 1] === ' ' || t[tIdx - 1] === '-') {
        score += 15;
      }
      
      consecutive++;
      qIdx++;
    } else {
      consecutive = 0;
      score -= 1; 
    }
    tIdx++;
  }
  
  if (qIdx < q.length) return 0; 
  
  if (t.includes(q)) score += 20;
  if (t === q) score += 50;
  
  return Math.max(0, score);
}
