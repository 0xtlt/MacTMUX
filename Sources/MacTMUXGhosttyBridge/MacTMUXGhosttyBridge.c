#include "MacTMUXGhosttyBridge.h"

#include <dlfcn.h>
#include <stdlib.h>
#include <string.h>

typedef enum {
  GHOSTTY_SUCCESS = 0,
} GhosttyResult;

typedef enum {
  GHOSTTY_BUILD_INFO_SIMD = 1,
} GhosttyBuildInfo;

typedef enum {
  GHOSTTY_POINT_TAG_ACTIVE = 0,
  GHOSTTY_POINT_TAG_VIEWPORT = 1,
  GHOSTTY_POINT_TAG_SCREEN = 2,
  GHOSTTY_POINT_TAG_HISTORY = 3,
} GhosttyPointTag;

typedef enum {
  GHOSTTY_SCROLL_VIEWPORT_TOP = 0,
  GHOSTTY_SCROLL_VIEWPORT_BOTTOM = 1,
  GHOSTTY_SCROLL_VIEWPORT_DELTA = 2,
} GhosttyTerminalScrollViewportTag;

typedef enum {
  GHOSTTY_FORMATTER_FORMAT_PLAIN = 0,
  GHOSTTY_FORMATTER_FORMAT_VT = 1,
  GHOSTTY_FORMATTER_FORMAT_HTML = 2,
} GhosttyFormatterFormat;

typedef struct GhosttyTerminalImpl *GhosttyTerminal;
typedef struct GhosttyFormatterImpl *GhosttyFormatter;
typedef struct GhosttyAllocator GhosttyAllocator;
typedef struct GhosttySelection GhosttySelection;
typedef struct GhosttyGridRef GhosttyGridRef;

typedef struct {
  uint16_t cols;
  uint16_t rows;
  size_t max_scrollback;
} GhosttyTerminalOptions;

typedef struct {
  size_t size;
  bool cursor;
  bool style;
  bool hyperlink;
  bool protection;
  bool kitty_keyboard;
  bool charsets;
} GhosttyFormatterScreenExtra;

typedef struct {
  size_t size;
  bool palette;
  bool modes;
  bool scrolling_region;
  bool tabstops;
  bool pwd;
  bool keyboard;
  GhosttyFormatterScreenExtra screen;
} GhosttyFormatterTerminalExtra;

typedef struct {
  size_t size;
  GhosttyFormatterFormat emit;
  bool unwrap;
  bool trim;
  GhosttyFormatterTerminalExtra extra;
  const GhosttySelection *selection;
} GhosttyFormatterTerminalOptions;

typedef struct {
  uint16_t x;
  uint32_t y;
} GhosttyPointCoordinate;

typedef union {
  GhosttyPointCoordinate coordinate;
  uint64_t _padding[2];
} GhosttyPointValue;

typedef struct {
  GhosttyPointTag tag;
  GhosttyPointValue value;
} GhosttyPoint;

struct GhosttyGridRef {
  size_t size;
  void *node;
  uint16_t x;
  uint16_t y;
};

struct GhosttySelection {
  size_t size;
  GhosttyGridRef start;
  GhosttyGridRef end;
  bool rectangle;
};

typedef struct {
  size_t size;
  GhosttyFormatterFormat emit;
  bool unwrap;
  bool trim;
  const GhosttySelection *selection;
} GhosttyTerminalSelectionFormatOptions;

typedef union {
  intptr_t delta;
  uint64_t _padding[2];
} GhosttyTerminalScrollViewportValue;

typedef struct {
  GhosttyTerminalScrollViewportTag tag;
  GhosttyTerminalScrollViewportValue value;
} GhosttyTerminalScrollViewport;

typedef GhosttyResult (*GhosttyBuildInfoFn)(GhosttyBuildInfo data, void *out);
typedef GhosttyResult (*GhosttyTerminalNewFn)(const GhosttyAllocator *allocator,
                                              GhosttyTerminal *terminal,
                                              GhosttyTerminalOptions options);
typedef void (*GhosttyTerminalFreeFn)(GhosttyTerminal terminal);
typedef GhosttyResult (*GhosttyTerminalResizeFn)(GhosttyTerminal terminal,
                                                 uint16_t cols,
                                                 uint16_t rows,
                                                 uint32_t cell_width_px,
                                                 uint32_t cell_height_px);
typedef void (*GhosttyTerminalVTWriteFn)(GhosttyTerminal terminal,
                                         const uint8_t *data,
                                         size_t len);
typedef GhosttyResult (*GhosttyFormatterTerminalNewFn)(const GhosttyAllocator *allocator,
                                                       GhosttyFormatter *formatter,
                                                       GhosttyTerminal terminal,
                                                       GhosttyFormatterTerminalOptions options);
typedef GhosttyResult (*GhosttyFormatterFormatAllocFn)(GhosttyFormatter formatter,
                                                       const GhosttyAllocator *allocator,
                                                       uint8_t **out_ptr,
                                                       size_t *out_len);
typedef void (*GhosttyFormatterFreeFn)(GhosttyFormatter formatter);
typedef void (*GhosttyTerminalScrollViewportFn)(GhosttyTerminal terminal,
                                                GhosttyTerminalScrollViewport behavior);
typedef GhosttyResult (*GhosttyTerminalGridRefFn)(GhosttyTerminal terminal,
                                                  GhosttyPoint point,
                                                  GhosttyGridRef *out_ref);
typedef GhosttyResult (*GhosttyTerminalSelectionFormatAllocFn)(GhosttyTerminal terminal,
                                                               const GhosttyAllocator *allocator,
                                                               GhosttyTerminalSelectionFormatOptions options,
                                                               uint8_t **out_ptr,
                                                               size_t *out_len);
typedef void (*GhosttyFreeFn)(const GhosttyAllocator *allocator,
                              uint8_t *ptr,
                              size_t len);

struct MCTGhosttyVTBridge {
  void *handle;
  GhosttyBuildInfoFn build_info;
  GhosttyTerminalNewFn terminal_new;
  GhosttyTerminalFreeFn terminal_free;
  GhosttyTerminalResizeFn terminal_resize;
  GhosttyTerminalVTWriteFn terminal_vt_write;
  GhosttyFormatterTerminalNewFn formatter_terminal_new;
  GhosttyFormatterFormatAllocFn formatter_format_alloc;
  GhosttyFormatterFreeFn formatter_free;
  GhosttyTerminalScrollViewportFn terminal_scroll_viewport;
  GhosttyTerminalGridRefFn terminal_grid_ref;
  GhosttyTerminalSelectionFormatAllocFn terminal_selection_format_alloc;
  GhosttyFreeFn ghostty_free;
};

struct MCTGhosttyVTTerminal {
  MCTGhosttyVTBridge *bridge;
  GhosttyTerminal terminal;
  uint16_t cols;
  uint16_t rows;
};

static void *mct_symbol(void *handle, const char *name) {
  return dlsym(handle, name);
}

MCTGhosttyVTBridge *MCTGhosttyVTBridgeCreate(const char *path) {
  if (path == NULL) {
    return NULL;
  }

  void *handle = dlopen(path, RTLD_NOW | RTLD_LOCAL);
  if (handle == NULL) {
    return NULL;
  }

  MCTGhosttyVTBridge *bridge = calloc(1, sizeof(MCTGhosttyVTBridge));
  if (bridge == NULL) {
    dlclose(handle);
    return NULL;
  }

  bridge->handle = handle;
  bridge->build_info = (GhosttyBuildInfoFn)mct_symbol(handle, "ghostty_build_info");
  bridge->terminal_new = (GhosttyTerminalNewFn)mct_symbol(handle, "ghostty_terminal_new");
  bridge->terminal_free = (GhosttyTerminalFreeFn)mct_symbol(handle, "ghostty_terminal_free");
  bridge->terminal_resize = (GhosttyTerminalResizeFn)mct_symbol(handle, "ghostty_terminal_resize");
  bridge->terminal_vt_write = (GhosttyTerminalVTWriteFn)mct_symbol(handle, "ghostty_terminal_vt_write");
  bridge->formatter_terminal_new = (GhosttyFormatterTerminalNewFn)mct_symbol(handle, "ghostty_formatter_terminal_new");
  bridge->formatter_format_alloc = (GhosttyFormatterFormatAllocFn)mct_symbol(handle, "ghostty_formatter_format_alloc");
  bridge->formatter_free = (GhosttyFormatterFreeFn)mct_symbol(handle, "ghostty_formatter_free");
  bridge->terminal_scroll_viewport = (GhosttyTerminalScrollViewportFn)mct_symbol(handle, "ghostty_terminal_scroll_viewport");
  bridge->terminal_grid_ref = (GhosttyTerminalGridRefFn)mct_symbol(handle, "ghostty_terminal_grid_ref");
  bridge->terminal_selection_format_alloc = (GhosttyTerminalSelectionFormatAllocFn)mct_symbol(handle, "ghostty_terminal_selection_format_alloc");
  bridge->ghostty_free = (GhosttyFreeFn)mct_symbol(handle, "ghostty_free");

  if (bridge->build_info == NULL ||
      bridge->terminal_new == NULL ||
      bridge->terminal_free == NULL ||
      bridge->terminal_resize == NULL ||
      bridge->terminal_vt_write == NULL ||
      bridge->formatter_terminal_new == NULL ||
      bridge->formatter_format_alloc == NULL ||
      bridge->formatter_free == NULL ||
      bridge->terminal_scroll_viewport == NULL ||
      bridge->terminal_grid_ref == NULL ||
      bridge->terminal_selection_format_alloc == NULL ||
      bridge->ghostty_free == NULL) {
    MCTGhosttyVTBridgeFree(bridge);
    return NULL;
  }

  return bridge;
}

void MCTGhosttyVTBridgeFree(MCTGhosttyVTBridge *bridge) {
  if (bridge == NULL) {
    return;
  }
  if (bridge->handle != NULL) {
    dlclose(bridge->handle);
  }
  free(bridge);
}

MCTGhosttyVTBuildInfo MCTGhosttyVTBridgeBuildInfo(MCTGhosttyVTBridge *bridge) {
  MCTGhosttyVTBuildInfo info = {false, false};
  if (bridge == NULL || bridge->build_info == NULL) {
    return info;
  }

  bool simd = false;
  if (bridge->build_info(GHOSTTY_BUILD_INFO_SIMD, &simd) == GHOSTTY_SUCCESS) {
    info.available = true;
    info.simd = simd;
  }
  return info;
}

MCTGhosttyVTTerminal *MCTGhosttyVTTerminalCreate(MCTGhosttyVTBridge *bridge,
                                                 uint16_t cols,
                                                 uint16_t rows) {
  if (bridge == NULL || bridge->terminal_new == NULL) {
    return NULL;
  }

  GhosttyTerminal terminal = NULL;
  GhosttyTerminalOptions options = {
    .cols = cols == 0 ? 1 : cols,
    .rows = rows == 0 ? 1 : rows,
    .max_scrollback = 0,
  };
  if (bridge->terminal_new(NULL, &terminal, options) != GHOSTTY_SUCCESS || terminal == NULL) {
    return NULL;
  }

  MCTGhosttyVTTerminal *wrapper = calloc(1, sizeof(MCTGhosttyVTTerminal));
  if (wrapper == NULL) {
    bridge->terminal_free(terminal);
    return NULL;
  }

  wrapper->bridge = bridge;
  wrapper->terminal = terminal;
  wrapper->cols = options.cols;
  wrapper->rows = options.rows;
  return wrapper;
}

void MCTGhosttyVTTerminalFree(MCTGhosttyVTTerminal *terminal) {
  if (terminal == NULL) {
    return;
  }
  if (terminal->bridge != NULL && terminal->bridge->terminal_free != NULL) {
    terminal->bridge->terminal_free(terminal->terminal);
  }
  free(terminal);
}

void MCTGhosttyVTTerminalResize(MCTGhosttyVTTerminal *terminal,
                                uint16_t cols,
                                uint16_t rows,
                                uint32_t cell_width_px,
                                uint32_t cell_height_px) {
  if (terminal == NULL || terminal->bridge == NULL || terminal->bridge->terminal_resize == NULL) {
    return;
  }
  terminal->bridge->terminal_resize(
    terminal->terminal,
    cols == 0 ? 1 : cols,
    rows == 0 ? 1 : rows,
    cell_width_px,
    cell_height_px
  );
  terminal->cols = cols == 0 ? 1 : cols;
  terminal->rows = rows == 0 ? 1 : rows;
}

bool MCTGhosttyVTTerminalRender(MCTGhosttyVTTerminal *terminal,
                                const uint8_t *data,
                                size_t data_len,
                                uint8_t **out_ptr,
                                size_t *out_len) {
  return MCTGhosttyVTTerminalRenderFormat(
    terminal,
    data,
    data_len,
    MCT_GHOSTTY_VT_RENDER_FORMAT_PLAIN,
    out_ptr,
    out_len
  );
}

bool MCTGhosttyVTTerminalRenderFormat(MCTGhosttyVTTerminal *terminal,
                                      const uint8_t *data,
                                      size_t data_len,
                                      MCTGhosttyVTRenderFormat format,
                                      uint8_t **out_ptr,
                                      size_t *out_len) {
  if (out_ptr == NULL || out_len == NULL) {
    return false;
  }
  *out_ptr = NULL;
  *out_len = 0;

  if (terminal == NULL || terminal->bridge == NULL) {
    return false;
  }

  MCTGhosttyVTBridge *bridge = terminal->bridge;
  bridge->terminal_vt_write(terminal->terminal, data, data_len);
  bridge->terminal_scroll_viewport(
    terminal->terminal,
    (GhosttyTerminalScrollViewport){
      .tag = GHOSTTY_SCROLL_VIEWPORT_BOTTOM,
      .value = {0},
    }
  );

  bool styled_output = format != MCT_GHOSTTY_VT_RENDER_FORMAT_PLAIN;
  GhosttyFormatterFormat emit = GHOSTTY_FORMATTER_FORMAT_PLAIN;
  if (format == MCT_GHOSTTY_VT_RENDER_FORMAT_VT) {
    emit = GHOSTTY_FORMATTER_FORMAT_VT;
  } else if (format == MCT_GHOSTTY_VT_RENDER_FORMAT_HTML) {
    emit = GHOSTTY_FORMATTER_FORMAT_HTML;
  }

  GhosttyGridRef viewport_start = {
    .size = sizeof(GhosttyGridRef),
  };
  GhosttyGridRef viewport_end = {
    .size = sizeof(GhosttyGridRef),
  };
  GhosttyPoint start_point = {
    .tag = GHOSTTY_POINT_TAG_VIEWPORT,
    .value = {
      .coordinate = {
        .x = 0,
        .y = 0,
      },
    },
  };
  GhosttyPoint end_point = {
    .tag = GHOSTTY_POINT_TAG_VIEWPORT,
    .value = {
      .coordinate = {
        .x = terminal->cols > 0 ? (uint16_t)(terminal->cols - 1) : 0,
        .y = terminal->rows > 0 ? (uint32_t)(terminal->rows - 1) : 0,
      },
    },
  };
  if (bridge->terminal_grid_ref(terminal->terminal, start_point, &viewport_start) == GHOSTTY_SUCCESS &&
      bridge->terminal_grid_ref(terminal->terminal, end_point, &viewport_end) == GHOSTTY_SUCCESS) {
    GhosttySelection viewport_selection = {
      .size = sizeof(GhosttySelection),
      .start = viewport_start,
      .end = viewport_end,
      .rectangle = false,
    };
    GhosttyTerminalSelectionFormatOptions selection_options = {
      .size = sizeof(GhosttyTerminalSelectionFormatOptions),
      .emit = emit,
      .unwrap = false,
      .trim = !styled_output,
      .selection = &viewport_selection,
    };
    uint8_t *ghostty_ptr = NULL;
    size_t ghostty_len = 0;
    if (bridge->terminal_selection_format_alloc(
          terminal->terminal,
          NULL,
          selection_options,
          &ghostty_ptr,
          &ghostty_len
        ) == GHOSTTY_SUCCESS &&
        ghostty_ptr != NULL) {
      uint8_t *copy = malloc(ghostty_len);
      if (copy != NULL) {
        memcpy(copy, ghostty_ptr, ghostty_len);
        *out_ptr = copy;
        *out_len = ghostty_len;
        bridge->ghostty_free(NULL, ghostty_ptr, ghostty_len);
        return true;
      }
      bridge->ghostty_free(NULL, ghostty_ptr, ghostty_len);
      return false;
    }
  }

  GhosttyFormatter formatter = NULL;
  GhosttyFormatterTerminalOptions options = {
    .size = sizeof(GhosttyFormatterTerminalOptions),
    .emit = emit,
    .unwrap = false,
    .trim = !styled_output,
    .extra = {
      .size = sizeof(GhosttyFormatterTerminalExtra),
      .palette = styled_output,
      .modes = styled_output,
      .scrolling_region = styled_output,
      .tabstops = styled_output,
      .pwd = false,
      .keyboard = false,
      .screen = {
        .size = sizeof(GhosttyFormatterScreenExtra),
        .cursor = false,
        .style = styled_output,
        .hyperlink = styled_output,
        .protection = false,
        .kitty_keyboard = false,
        .charsets = styled_output,
      },
    },
    .selection = NULL,
  };

  if (bridge->formatter_terminal_new(NULL, &formatter, terminal->terminal, options) != GHOSTTY_SUCCESS ||
      formatter == NULL) {
    return false;
  }

  uint8_t *ghostty_ptr = NULL;
  size_t ghostty_len = 0;
  bool ok = false;
  if (bridge->formatter_format_alloc(formatter, NULL, &ghostty_ptr, &ghostty_len) == GHOSTTY_SUCCESS &&
      ghostty_ptr != NULL) {
    uint8_t *copy = malloc(ghostty_len);
    if (copy != NULL) {
      memcpy(copy, ghostty_ptr, ghostty_len);
      *out_ptr = copy;
      *out_len = ghostty_len;
      ok = true;
    }
    bridge->ghostty_free(NULL, ghostty_ptr, ghostty_len);
  }

  bridge->formatter_free(formatter);
  return ok;
}

void MCTGhosttyVTBufferFree(uint8_t *ptr) {
  free(ptr);
}
