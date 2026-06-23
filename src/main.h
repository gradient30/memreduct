// Mem Reduct
// Copyright (c) 2011-2026 Henry++

#pragma once

#include "routine.h"

#include "resource.h"
#include "app.h"

// memreduct uses 3-arg config helpers; map to routine _ex API
#define _r_config_getboolean(key, def, section) _r_config_getboolean_ex ((key), (def), (section))
#define _r_config_getlong(key, def, section) _r_config_getlong_ex ((key), (def), (section))
#define _r_config_getlong64(key, def, section) _r_config_getlong64_ex ((key), (def), (section))
#define _r_config_getulong(key, def, section) _r_config_getulong_ex ((key), (def), (section))
#define _r_config_getulong64(key, def, section) _r_config_getulong64_ex ((key), (def), (section))
#define _r_config_setboolean(key, val, section) _r_config_setboolean_ex ((key), (val), (section))
#define _r_config_setlong(key, val, section) _r_config_setlong_ex ((key), (val), (section))
#define _r_config_setlong64(key, val, section) _r_config_setlong64_ex ((key), (val), (section))
#define _r_config_setulong(key, val, section) _r_config_setulong_ex ((key), (val), (section))
#define _r_config_setulong64(key, val, section) _r_config_setulong64_ex ((key), (val), (section))
#define _r_config_setstring(key, val, section) _r_config_setstring_ex ((key), (val), (section))
#define _r_config_getfont(key, logfont, dpi, section) _r_config_getfont_ex ((key), (logfont), (dpi), (section))
#define _r_config_setfont(key, logfont, dpi, section) _r_config_setfont_ex ((key), (logfont), (dpi), (section))

DEFINE_GUID (GUID_TrayIcon, 0xAE9053F0, 0x8D59, 0x4803, 0x9A, 0xBB, 0x74, 0xAF, 0xE6, 0x6B, 0x5F, 0xD2);

LPWSTR _app_get_region_title (
	_In_ ULONG mask_bit
);

#define TIMER 1000
#define UID 1337

#define LANG_SUBMENU 1
#define LANG_MENU 4

#define TRAY_SUBMENU_1 4
#define TRAY_SUBMENU_2 5
#define TRAY_SUBMENU_3 6

#define DEFAULT_AUTOREDUCT_VAL 90
#define DEFAULT_AUTOREDUCTINTERVAL_VAL 30

#define DEFAULT_DANGER_LEVEL 90
#define DEFAULT_WARNING_LEVEL 70

// colors
#define TRAY_COLOR_BLACK RGB(0x00, 0x00, 0x00)
#define TRAY_COLOR_WHITE RGB(0xFF, 0xFF, 0xFF)
#define TRAY_COLOR_TEXT RGB(0xFF, 0xFF, 0xFF)
#define TRAY_COLOR_BG RGB(0x00, 0x80, 0x40)
#define TRAY_COLOR_WARNING RGB(0xFF, 0x80, 0x40)
#define TRAY_COLOR_DANGER RGB(0xEC, 0x1C, 0x24)

// memory cleaning mask
#define REDUCT_WORKING_SET 0x01
#define REDUCT_SYSTEM_FILE_CACHE 0x02
#define REDUCT_STANDBY_PRIORITY0_LIST 0x04
#define REDUCT_STANDBY_LIST 0x08
#define REDUCT_MODIFIED_LIST 0x10
#define REDUCT_COMBINE_MEMORY_LISTS 0x20
#define REDUCT_REGISTRY_CACHE 0x40
#define REDUCT_MODIFIED_FILE_CACHE 0x80

// memory cleaning values
#define REDUCT_MASK_ALL (REDUCT_WORKING_SET | \
REDUCT_SYSTEM_FILE_CACHE | \
REDUCT_STANDBY_PRIORITY0_LIST | \
REDUCT_STANDBY_LIST | \
REDUCT_MODIFIED_LIST | \
REDUCT_COMBINE_MEMORY_LISTS | \
REDUCT_REGISTRY_CACHE | \
REDUCT_MODIFIED_FILE_CACHE)

#define REDUCT_MASK_DEFAULT (REDUCT_WORKING_SET | REDUCT_SYSTEM_FILE_CACHE | REDUCT_STANDBY_PRIORITY0_LIST | REDUCT_REGISTRY_CACHE | REDUCT_COMBINE_MEMORY_LISTS | REDUCT_MODIFIED_FILE_CACHE)
#define REDUCT_MASK_FREEZES (REDUCT_STANDBY_LIST | REDUCT_MODIFIED_LIST)

typedef struct _STATIC_DATA
{
	HDC hdc;
	HDC hdc_mask;
	HBITMAP hbitmap;
	HBITMAP hbitmap_mask;
	HFONT hfont;
	RECT icon_size;
	ULONG ms_prev;
} STATIC_DATA, *PSTATIC_DATA;

typedef enum _CLEANUP_SOURCE_ENUM
{
	SOURCE_AUTO,
	SOURCE_MANUAL,
	SOURCE_HOTKEY,
	SOURCE_CMDLINE
} CLEANUP_SOURCE_ENUM, *PCLEANUP_SOURCE_ENUM;
