// Configure your import map in config/importmap.rb. Read more: https://github.com/rails/importmap-rails
import "@hotwired/turbo-rails"
import "controllers"

const SCROLL_STORAGE_KEY = "perfectcrm:list-scroll:v1"

function loadScrollState() {
  try {
    const raw = window.sessionStorage.getItem(SCROLL_STORAGE_KEY)
    if (raw) {
      const parsed = JSON.parse(raw)
      return {
        lists: parsed.lists && typeof parsed.lists === "object" ? parsed.lists : {},
        restorations: parsed.restorations && typeof parsed.restorations === "object" ? parsed.restorations : {},
        lastPageUrl: typeof parsed.lastPageUrl === "string" ? parsed.lastPageUrl : null,
        pendingBackRestore: Boolean(parsed.pendingBackRestore)
      }
    }
  } catch {
    // Ignore storage errors in restricted browsing modes.
  }
  return { lists: {}, restorations: {}, lastPageUrl: null, pendingBackRestore: false }
}

const scrollState = loadScrollState()

function persistScrollState() {
  try {
    window.sessionStorage.setItem(SCROLL_STORAGE_KEY, JSON.stringify(scrollState))
  } catch {
    // Ignore storage errors in restricted browsing modes.
  }
}

function listKeyForLocation(urlLike, root = document) {
  try {
    const url = new URL(urlLike, window.location.origin)
    if (url.origin !== window.location.origin) return null
    const path = url.pathname.replace(/\/+$/, "") || "/"
    const params = url.searchParams
    if (path === "/leads") {
      let tab = params.get("tab")
      if (!tab && root) {
        const activeTab = root.querySelector?.('nav.tabs a[aria-current="page"]')
        if (activeTab) {
          tab = new URL(activeTab.href, window.location.origin).searchParams.get("tab")
        }
      }
      tab = tab || "new"
      const sort = params.get("sort") || "activity"
      const q = (params.get("q") || "").trim()
      return `leads:${tab}:${sort}:${q}`
    }
    if (path === "/clients") {
      const tab = params.get("tab") || "clients"
      const sort = params.get("sort") || "activity"
      const q = (params.get("q") || "").trim()
      return `clients:${tab}:${sort}:${q}`
    }
    return null
  } catch {
    return null
  }
}

function listFamilyForPath(pathname) {
  const path = (pathname || "").replace(/\/+$/, "") || "/"
  if (path === "/leads" || /^\/leads\/[^/]+/.test(path)) return "leads"
  if (path === "/clients" || /^\/(clients|organizations)\/[^/]+/.test(path)) return "clients"
  return null
}

function isRecordPath(pathname) {
  const path = (pathname || "").replace(/\/+$/, "") || "/"
  return /^\/(leads|clients|organizations)\/[^/]+/.test(path)
}

function findRowRecordLink(row) {
  if (!row) return null
  return Array.from(row.querySelectorAll("a[href]")).find((a) => {
    try {
      return /^\/(leads|clients|organizations)\/\d+$/.test(new URL(a.href, window.location.origin).pathname)
    } catch {
      return false
    }
  })
}

function syncTurboRestorationData() {
  const historyObj = window.Turbo?.navigator?.history
  if (!historyObj?.restorationData) return
  for (const [id, pos] of Object.entries(scrollState.restorations)) {
    if (pos && typeof pos.y === "number" && !historyObj.restorationData[id]?.scrollPosition) {
      historyObj.restorationData[id] = {
        ...historyObj.restorationData[id],
        scrollPosition: { x: pos.x || 0, y: pos.y }
      }
    }
  }
}

let currentPage = {
  url: window.location.href,
  listKey: listKeyForLocation(window.location.href, document),
  restorationId: window.history.state?.turbo?.restorationIdentifier || null
}
let isTransitioning = false
let popstateRestore = false
let activeRestoreTarget = null
let hasHandledInitialLoad = false

function saveCurrentListScroll(clickedElement = null) {
  if (currentPage.listKey) {
    const prev = scrollState.lists[currentPage.listKey] || {}
    const entry = {
      ...prev,
      scrollY: window.scrollY,
      scrollX: window.scrollX
    }
    if (clickedElement instanceof Element) {
      const row = clickedElement.closest("main section.card ul > li")
      if (row) {
        const recordLink = findRowRecordLink(row)
        if (recordLink) {
          entry.recordPath = new URL(recordLink.href, window.location.origin).pathname
          entry.viewportOffset = row.getBoundingClientRect().top
          entry.rowIndex = row.parentElement ? Array.from(row.parentElement.children).indexOf(row) : null
        }
      }
    }
    scrollState.lists[currentPage.listKey] = entry
  }

  const restorationId = currentPage.restorationId || window.history.state?.turbo?.restorationIdentifier
  if (restorationId) {
    scrollState.restorations[restorationId] = { x: window.scrollX, y: window.scrollY }
    if (window.Turbo?.navigator?.history?.restorationData) {
      window.Turbo.navigator.history.restorationData[restorationId] = {
        ...window.Turbo.navigator.history.restorationData[restorationId],
        scrollPosition: { x: window.scrollX, y: window.scrollY }
      }
    }
  }

  persistScrollState()
}

function computeTargetScrollY(saved) {
  if (!saved) return 0
  if (saved.recordPath) {
    const rows = Array.from(document.querySelectorAll("main section.card ul > li"))
    const matchIndex = rows.findIndex((li) => {
      const link = findRowRecordLink(li)
      if (!link) return false
      try {
        return new URL(link.href, window.location.origin).pathname === saved.recordPath
      } catch {
        return false
      }
    })
    const jumpedToTop = matchIndex === 0 && typeof saved.rowIndex === "number" && saved.rowIndex > 1
    const stayedNearIndex =
      matchIndex !== -1 &&
      !jumpedToTop &&
      (saved.rowIndex == null || Math.abs(matchIndex - saved.rowIndex) <= 2)
    if (stayedNearIndex) {
      const row = rows[matchIndex]
      const rowDocTop = row.getBoundingClientRect().top + window.scrollY
      const offset = typeof saved.viewportOffset === "number" ? saved.viewportOffset : 160
      return Math.max(0, Math.round(rowDocTop - offset))
    }
  }
  return Math.max(0, Math.round(saved.scrollY || 0))
}

function resolveRestoreTarget(newBody = document.body) {
  const newListKey = listKeyForLocation(window.location.href, newBody)
  if (!newListKey) return null

  const saved = scrollState.lists[newListKey]
  if (!saved) return null

  const visitAction = window.Turbo?.navigator?.currentVisit?.action
  const prevUrl = currentPage.url !== window.location.href ? currentPage.url : scrollState.lastPageUrl
  let fromRecordInSameFamily = false
  if (prevUrl) {
    try {
      const prevPathname = new URL(prevUrl, window.location.origin).pathname
      fromRecordInSameFamily =
        isRecordPath(prevPathname) &&
        listFamilyForPath(prevPathname) === listFamilyForPath(window.location.pathname)
    } catch {
      fromRecordInSameFamily = false
    }
  }

  if (visitAction === "restore" || popstateRestore || scrollState.pendingBackRestore || fromRecordInSameFamily) {
    return { listKey: newListKey, saved }
  }
  return null
}

function applyRestoredScroll(listKey, saved) {
  const targetY = computeTargetScrollY(saved)
  const targetX = saved.scrollX || 0
  window.scrollTo({ top: targetY, left: targetX, behavior: "instant" })
  if (window.Turbo?.navigator?.currentVisit) {
    window.Turbo.navigator.currentVisit.scrolled = true
  }
  const restorationId = window.history.state?.turbo?.restorationIdentifier
  if (restorationId) {
    scrollState.restorations[restorationId] = { x: targetX, y: targetY }
    if (window.Turbo?.navigator?.history) {
      window.Turbo.navigator.history.updateRestorationData({
        scrollPosition: { x: targetX, y: targetY }
      })
    }
  }
  scrollState.lists[listKey] = { ...saved, scrollY: targetY, scrollX: targetX }
  persistScrollState()
}

window.addEventListener(
  "scroll",
  () => {
    if (!isTransitioning && currentPage.listKey) {
      saveCurrentListScroll()
    }
  },
  { passive: true }
)

window.addEventListener(
  "popstate",
  () => {
    isTransitioning = true
    popstateRestore = true
    syncTurboRestorationData()
  },
  true
)

window.addEventListener("pagehide", () => {
  if (!isTransitioning && currentPage.listKey) {
    saveCurrentListScroll()
  }
})

document.addEventListener(
  "click",
  (event) => {
    const target = event.target instanceof Element ? event.target : null
    const link = target?.closest("a[href]")
    if (!isTransitioning && currentPage.listKey) {
      saveCurrentListScroll(link || target)
    }
    if (!link) return

    if (link.closest(".page-header") && !link.closest(".page-actions")) {
      scrollState.pendingBackRestore = true
    } else if (link.closest('nav[aria-label="Primary"], .tabbar, nav.tabs')) {
      scrollState.pendingBackRestore = false
    } else {
      try {
        const currentPathname = new URL(currentPage.url, window.location.origin).pathname
        if (isRecordPath(currentPathname) && listKeyForLocation(link.href)) {
          scrollState.pendingBackRestore = true
        }
      } catch {
        // Ignore invalid URLs.
      }
    }
    scrollState.lastPageUrl = currentPage.url
    persistScrollState()
  },
  true
)

document.addEventListener(
  "submit",
  (event) => {
    const form = event.target instanceof HTMLFormElement ? event.target : null
    const submitter = event.submitter instanceof Element ? event.submitter : form
    if (!isTransitioning && currentPage.listKey) {
      saveCurrentListScroll(submitter)
      if (form?.closest("main section.card ul > li")) {
        scrollState.pendingBackRestore = true
      } else if (form && (form.getAttribute("method") || "").toLowerCase() === "get") {
        scrollState.pendingBackRestore = false
      }
    } else {
      try {
        const currentPathname = new URL(currentPage.url, window.location.origin).pathname
        if (isRecordPath(currentPathname)) {
          scrollState.pendingBackRestore = true
        }
      } catch {
        // Ignore invalid URLs.
      }
    }
    scrollState.lastPageUrl = currentPage.url
    persistScrollState()
  },
  true
)

document.addEventListener("turbo:before-visit", () => {
  if (!isTransitioning && currentPage.listKey) {
    saveCurrentListScroll()
  }
  scrollState.lastPageUrl = currentPage.url
  isTransitioning = true
  persistScrollState()
})

document.addEventListener("turbo:before-cache", () => {
  document.querySelectorAll("details.call-schedule-pop[open]").forEach((el) => {
    el.open = false
  })
})

document.addEventListener("turbo:before-render", (event) => {
  document.documentElement.dataset.scheme = event.detail.newBody.dataset.scheme || "paper"
  syncTurboRestorationData()
  activeRestoreTarget = resolveRestoreTarget(event.detail.newBody)
})

document.addEventListener("turbo:render", () => {
  const target = activeRestoreTarget || resolveRestoreTarget(document.body)
  if (target) {
    applyRestoredScroll(target.listKey, target.saved)
  }
})

document.addEventListener("turbo:load", () => {
  syncTurboRestorationData()
  const navEntry = window.performance?.getEntriesByType?.("navigation")?.[0]
  if (!hasHandledInitialLoad && navEntry?.type === "back_forward") {
    popstateRestore = true
  }
  hasHandledInitialLoad = true

  const target = activeRestoreTarget || resolveRestoreTarget(document.body)
  if (target) {
    applyRestoredScroll(target.listKey, target.saved)
  }

  activeRestoreTarget = null
  popstateRestore = false
  scrollState.pendingBackRestore = false
  scrollState.lastPageUrl = window.location.href
  currentPage = {
    url: window.location.href,
    listKey: listKeyForLocation(window.location.href, document.body),
    restorationId: window.history.state?.turbo?.restorationIdentifier || null
  }
  isTransitioning = false
  if (currentPage.listKey && !target) {
    saveCurrentListScroll()
  } else {
    persistScrollState()
  }
})
