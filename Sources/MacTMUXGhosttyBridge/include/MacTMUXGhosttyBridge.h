#ifndef MACTMUX_GHOSTTY_BRIDGE_H
#define MACTMUX_GHOSTTY_BRIDGE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct MCTGhosttyVTBridge MCTGhosttyVTBridge;
typedef struct MCTGhosttyVTTerminal MCTGhosttyVTTerminal;

typedef struct {
  bool available;
  bool simd;
} MCTGhosttyVTBuildInfo;

typedef enum {
  MCT_GHOSTTY_VT_RENDER_FORMAT_PLAIN = 0,
  MCT_GHOSTTY_VT_RENDER_FORMAT_VT = 1,
  MCT_GHOSTTY_VT_RENDER_FORMAT_HTML = 2,
} MCTGhosttyVTRenderFormat;

MCTGhosttyVTBridge *MCTGhosttyVTBridgeCreate(const char *path);
void MCTGhosttyVTBridgeFree(MCTGhosttyVTBridge *bridge);
MCTGhosttyVTBuildInfo MCTGhosttyVTBridgeBuildInfo(MCTGhosttyVTBridge *bridge);

MCTGhosttyVTTerminal *MCTGhosttyVTTerminalCreate(MCTGhosttyVTBridge *bridge,
                                                 uint16_t cols,
                                                 uint16_t rows);
void MCTGhosttyVTTerminalFree(MCTGhosttyVTTerminal *terminal);
void MCTGhosttyVTTerminalResize(MCTGhosttyVTTerminal *terminal,
                                uint16_t cols,
                                uint16_t rows,
                                uint32_t cell_width_px,
                                uint32_t cell_height_px);
bool MCTGhosttyVTTerminalRender(MCTGhosttyVTTerminal *terminal,
                                const uint8_t *data,
                                size_t data_len,
                                uint8_t **out_ptr,
                                size_t *out_len);
bool MCTGhosttyVTTerminalRenderFormat(MCTGhosttyVTTerminal *terminal,
                                      const uint8_t *data,
                                      size_t data_len,
                                      MCTGhosttyVTRenderFormat format,
                                      uint8_t **out_ptr,
                                      size_t *out_len);
void MCTGhosttyVTBufferFree(uint8_t *ptr);

#ifdef __cplusplus
}
#endif

#endif
