// Phase 0 compatibility fixture: records, including a nested record
// (rectangle.topleft/bottomright).
//
// Independently authored for cataggar/StarlingMonkey#6 (Phase 0).
function translate(point, dx, dy) {
  return { x: point.x + dx, y: point.y + dy };
}

function area(rect) {
  const width = rect.bottomright.x - rect.topleft.x;
  const height = rect.bottomright.y - rect.topleft.y;
  return width * height;
}

function identity(point) {
  return point;
}

export const api = { translate, area, identity };
