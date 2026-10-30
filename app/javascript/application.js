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
        linkedFrom: typeof parsed.linkedFrom === "string" ? parsed.linkedFrom : null
      }
    }
  } catch {
    // Ignore storage errors in restricted browsing modes.
  }
  return { lists: {}, linkedFrom: null }
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

let currentPage = {
  pathname: window.location.pathname,
  listKey: listKeyForLocation(window.location.href, document)
}
let isTransitioning = false
let popstateRestore = false
let activeRestoreTarget = null
let hasHandledInitialLoad = false

function saveCurrentListScroll(clickedElement = null) {
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
        entry.anchorScrollY = entry.scrollY
      }
    }
  }
  scrollState.lists[currentPage.listKey] = entry
  persistScrollState()
}

function anchorIsCurrent(saved) {
  return (
    Boolean(saved.recordPath) &&
    typeof saved.anchorScrollY === "number" &&
    Math.abs((saved.scrollY || 0) - saved.anchorScrollY) < 1
  )
}

function computeTargetScrollY(saved) {
  if (anchorIsCurrent(saved)) {
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
  const linkedFromSavedRecord = Boolean(scrollState.linkedFrom) && scrollState.linkedFrom === saved.recordPath
  if (visitAction === "restore" || popstateRestore || linkedFromSavedRecord) {
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
  scrollState.lists[listKey] = {
    ...saved,
    scrollY: targetY,
    scrollX: targetX,
    anchorScrollY: anchorIsCurrent(saved) ? targetY : saved.anchorScrollY
  }
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

    const opensList = listKeyForLocation(link.href) && !link.closest('nav[aria-label="Primary"], .tabbar')
    scrollState.linkedFrom = opensList ? currentPage.pathname : null
    persistScrollState()
  },
  true
)

document.addEventListener("turbo:before-visit", () => {
  if (!isTransitioning && currentPage.listKey) {
    saveCurrentListScroll()
  }
  isTransitioning = true
})

document.addEventListener("turbo:before-render", (event) => {
  document.documentElement.dataset.scheme = event.detail.newBody.dataset.scheme || "paper"
  activeRestoreTarget = resolveRestoreTarget(event.detail.newBody)
})

document.addEventListener("turbo:render", () => {
  const target = activeRestoreTarget || resolveRestoreTarget(document.body)
  if (target) {
    applyRestoredScroll(target.listKey, target.saved)
  }
})

document.addEventListener("turbo:load", () => {
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
  scrollState.linkedFrom = null
  currentPage = {
    pathname: window.location.pathname,
    listKey: listKeyForLocation(window.location.href, document.body)
  }
  isTransitioning = false
  if (currentPage.listKey && !target) {
    saveCurrentListScroll()
  } else {
    persistScrollState()
  }
})
