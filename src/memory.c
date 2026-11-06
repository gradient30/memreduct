// Mem Reduct
// Copyright (c) 2011-2026 Henry++

#include "routine.h"

#include "memory.h"
#include "rapp.h"
#include "resource.h"

static CLEANUP_REGION_RESULT cleanup_results[REGION_COUNT];

#define CLEANUP_PERSIST_NOT_RUN 0UL
#define CLEANUP_PERSIST_SUCCESS 1UL
#define CLEANUP_PERSIST_SKIPPED 2UL

static ULONG _app_memory_persist_encode (
	_In_ CLEANUP_STATE_ENUM state,
	_In_ NTSTATUS status
)
{
	switch (state)
	{
		case CLEANUP_STATE_SUCCESS:
			return CLEANUP_PERSIST_SUCCESS;

		case CLEANUP_STATE_SKIPPED:
			return CLEANUP_PERSIST_SKIPPED;

		case CLEANUP_STATE_FAILED:
			return (ULONG)status;

		default:
			return CLEANUP_PERSIST_NOT_RUN;
	}
}

static VOID _app_memory_persist_decode (
	_In_ ULONG persist_value,
	_Out_ PCLEANUP_REGION_RESULT result
)
{
	if (persist_value == CLEANUP_PERSIST_NOT_RUN)
	{
		result->state = CLEANUP_STATE_NOT_RUN;
		result->status = STATUS_SUCCESS;
	}
	else if (persist_value == CLEANUP_PERSIST_SUCCESS)
	{
		result->state = CLEANUP_STATE_SUCCESS;
		result->status = STATUS_SUCCESS;
	}
	else if (persist_value == CLEANUP_PERSIST_SKIPPED)
	{
		result->state = CLEANUP_STATE_SKIPPED;
		result->status = STATUS_NOT_SUPPORTED;
	}
	else
	{
		result->status = (NTSTATUS)persist_value;
		result->state = CLEANUP_STATE_FAILED;
	}
}

static BOOL CALLBACK _app_memory_find_status_page (
	_In_ HWND hwnd,
	_In_ LPARAM lparam
)
{
	HWND hctrl;

	hctrl = GetDlgItem (hwnd, IDC_CLEANUP_STATUS);

	if (hctrl)
	{
		*(HWND *)lparam = hwnd;

		return FALSE;
	}

	return TRUE;
}

static LPWSTR _app_memory_region_name (
	_In_ CLEANUP_REGION_ENUM region
)
{
	return _app_get_region_title_by_enum (region);
}

static LPCWSTR _app_memory_config_key (
	_In_ CLEANUP_REGION_ENUM region
)
{
	switch (region)
	{
		case REGION_WORKING_SET:
			return L"LastCleanupWorkingSet";

		case REGION_SYSTEM_FILE_CACHE:
			return L"LastCleanupSystemFileCache";

		case REGION_MODIFIED_FILE_CACHE:
			return L"LastCleanupModifiedFileCache";

		case REGION_MODIFIED_LIST:
			return L"LastCleanupModifiedList";

		case REGION_STANDBY_LIST:
			return L"LastCleanupStandbyList";

		case REGION_STANDBY_PRIORITY0:
			return L"LastCleanupStandbyPriority0";

		case REGION_REGISTRY_CACHE:
			return L"LastCleanupRegistryCache";

		case REGION_COMBINE_MEMORY_LISTS:
			return L"LastCleanupCombineMemoryLists";

		default:
			return NULL;
	}
}

static VOID _app_memory_reset_results ()
{
	for (ULONG i = 0; i < REGION_COUNT; i++)
	{
		cleanup_results[i].state = CLEANUP_STATE_NOT_RUN;
		cleanup_results[i].status = STATUS_SUCCESS;
	}
}

static VOID _app_memory_record_result (
	_In_ CLEANUP_REGION_ENUM region,
	_In_ NTSTATUS status,
	_In_ BOOLEAN was_attempted
)
{
	PCLEANUP_REGION_RESULT result;
	LPCWSTR config_key;

	if (region >= REGION_COUNT)
		return;

	result = &cleanup_results[region];

	if (!was_attempted)
	{
		result->state = CLEANUP_STATE_NOT_RUN;
		result->status = STATUS_SUCCESS;

		config_key = _app_memory_config_key (region);

		if (config_key)
			_r_config_setulong (config_key, CLEANUP_PERSIST_NOT_RUN, NULL);

		return;
	}

	result->status = status;
	result->state = NT_SUCCESS (status) ? CLEANUP_STATE_SUCCESS : CLEANUP_STATE_FAILED;

	config_key = _app_memory_config_key (region);

	if (config_key)
		_r_config_setulong (config_key, _app_memory_persist_encode (result->state, status), NULL);
}

static VOID _app_memory_record_skip (
	_In_ CLEANUP_REGION_ENUM region
)
{
	PCLEANUP_REGION_RESULT result;
	LPCWSTR config_key;

	if (region >= REGION_COUNT)
		return;

	result = &cleanup_results[region];
	result->state = CLEANUP_STATE_SKIPPED;
	result->status = STATUS_NOT_SUPPORTED;

	config_key = _app_memory_config_key (region);

	if (config_key)
		_r_config_setulong (config_key, CLEANUP_PERSIST_SKIPPED, NULL);
}

VOID _app_memory_init_from_config ()
{
	ULONG status_value;
	LPCWSTR config_key;

	for (ULONG i = 0; i < REGION_COUNT; i++)
	{
		config_key = _app_memory_config_key ((CLEANUP_REGION_ENUM)i);

		if (!config_key)
			continue;

		status_value = _r_config_getulong (config_key, CLEANUP_PERSIST_NOT_RUN, NULL);

		_app_memory_persist_decode (status_value, &cleanup_results[i]);
	}
}

VOID _app_memory_init_privileges ()
{
	ULONG privileges[] = {
		SE_PROF_SINGLE_PROCESS_PRIVILEGE,
		SE_INCREASE_QUOTA_PRIVILEGE,
	};

	if (_r_sys_iselevated ())
		_r_sys_setprocessprivilege (NtCurrentProcess (), privileges, RTL_NUMBER_OF (privileges), TRUE);
}

ULONG64 _app_getmemoryinfo (
	_Out_ PR_MEMORY_INFO mem_info
)
{
	_r_sys_getmemoryinfo (mem_info);

	return mem_info->physical_memory.used_bytes;
}

NTSTATUS _app_flushvolumecache ()
{
	PMOUNTMGR_MOUNT_POINTS object_mountpoints;
	PMOUNTMGR_MOUNT_POINT mountpoint;
	OBJECT_ATTRIBUTES oa = {0};
	IO_STATUS_BLOCK isb;
	UNICODE_STRING us;
	HANDLE hdevice;
	HANDLE hvolume;
	NTSTATUS status;
	NTSTATUS last_status = STATUS_SUCCESS;

	RtlInitUnicodeString (&us, MOUNTMGR_DEVICE_NAME);

	InitializeObjectAttributes (&oa, &us, OBJ_CASE_INSENSITIVE, NULL, NULL);

	status = NtCreateFile (
		&hdevice,
		FILE_READ_ATTRIBUTES | SYNCHRONIZE,
		&oa,
		&isb,
		NULL,
		FILE_ATTRIBUTE_NORMAL,
		FILE_SHARE_READ | FILE_SHARE_WRITE,
		FILE_OPEN,
		FILE_NON_DIRECTORY_FILE | FILE_SYNCHRONOUS_IO_NONALERT,
		NULL,
		0
	);

	if (!NT_SUCCESS (status))
		return status;

	status = _r_fs_getvolumemountpoints (hdevice, &object_mountpoints);

	if (!NT_SUCCESS (status))
		goto CleanupExit;

	for (ULONG i = 0; i < object_mountpoints->NumberOfMountPoints; i++)
	{
		mountpoint = &object_mountpoints->MountPoints[i];

		us.Length = mountpoint->SymbolicLinkNameLength;
		us.MaximumLength = mountpoint->SymbolicLinkNameLength + sizeof (UNICODE_NULL);
		us.Buffer = PTR_ADD_OFFSET (object_mountpoints, mountpoint->SymbolicLinkNameOffset);

		if (MOUNTMGR_IS_VOLUME_NAME (&us))
		{
			InitializeObjectAttributes (&oa, &us, OBJ_CASE_INSENSITIVE, NULL, NULL);

			status = NtCreateFile (
				&hvolume,
				FILE_WRITE_DATA | SYNCHRONIZE,
				&oa,
				&isb,
				NULL,
				FILE_ATTRIBUTE_NORMAL,
				FILE_SHARE_READ | FILE_SHARE_WRITE,
				FILE_OPEN,
				FILE_NON_DIRECTORY_FILE | FILE_SYNCHRONOUS_IO_NONALERT,
				NULL,
				0
			);

			if (NT_SUCCESS (status))
			{
				status = _r_fs_flushfile (hvolume);

				if (!NT_SUCCESS (status))
					last_status = status;

				NtClose (hvolume);
			}
			else
			{
				last_status = status;
			}
		}
	}

	_r_mem_free (object_mountpoints);

CleanupExit:

	NtClose (hdevice);

	return last_status;
}

VOID _app_memoryclean (
	_In_opt_ HWND hwnd,
	_In_ CLEANUP_SOURCE_ENUM src,
	_In_opt_ ULONG mask
)
{
	MEMORY_COMBINE_INFORMATION_EX combine_info_ex = {0};
	SYSTEM_FILECACHE_INFORMATION sfci = {0};
	SYSTEM_MEMORY_LIST_COMMAND command;
	R_MEMORY_INFO mem_info;
	WCHAR buffer1[256] = {0};
	WCHAR buffer2[256] = {0};
	LPCWSTR error_text;
	ULONG64 reduct_before;
	ULONG64 reduct_after;
	ULONG flags = NIIF_WARNING;
	NTSTATUS status;

	if (!_r_config_getboolean (L"IsNotificationsSound", TRUE, NULL))
		flags |= NIIF_NOSOUND;

	if (!_r_sys_iselevated ())
	{
		error_text = _r_locale_getstring (IDS_STATUS_NOPRIVILEGES);

		if (_r_app_runasadmin ())
		{
			if (hwnd)
				DestroyWindow (hwnd);
		}
		else
		{
			if (src == SOURCE_CMDLINE)
			{
				if (hwnd)
					_r_show_message (hwnd, MB_OK | MB_ICONSTOP, NULL, error_text);
			}
			else
			{
				if (hwnd)
					_app_tray_popup (hwnd, flags, _r_app_getname (), error_text);
			}
		}

		return;
	}

	_app_memory_init_privileges ();

	if (!mask)
		mask = _r_config_getulong (L"ReductMask2", REDUCT_MASK_DEFAULT, NULL);

	if (src == SOURCE_AUTO)
	{
		if (!_r_config_getboolean (L"IsAllowStandbyListCleanup", FALSE, NULL))
			mask &= ~REDUCT_MASK_FREEZES;
	}
	else if (src == SOURCE_MANUAL)
	{
		WCHAR line[128];

		if ((mask & REDUCT_WORKING_SET) == REDUCT_WORKING_SET)
		{
			_r_str_printf (line, RTL_NUMBER_OF (line), L"- %s\r\n", _app_get_region_title (REDUCT_WORKING_SET));
			_r_str_append (buffer1, RTL_NUMBER_OF (buffer1), line);
		}

		if ((mask & REDUCT_SYSTEM_FILE_CACHE) == REDUCT_SYSTEM_FILE_CACHE)
		{
			_r_str_printf (line, RTL_NUMBER_OF (line), L"- %s\r\n", _app_get_region_title (REDUCT_SYSTEM_FILE_CACHE));
			_r_str_append (buffer1, RTL_NUMBER_OF (buffer1), line);
		}

		if ((mask & REDUCT_MODIFIED_FILE_CACHE) == REDUCT_MODIFIED_FILE_CACHE)
		{
			_r_str_printf (line, RTL_NUMBER_OF (line), L"- %s\r\n", _app_get_region_title (REDUCT_MODIFIED_FILE_CACHE));
			_r_str_append (buffer1, RTL_NUMBER_OF (buffer1), line);
		}

		if ((mask & REDUCT_MODIFIED_LIST) == REDUCT_MODIFIED_LIST)
		{
			_r_str_printf (line, RTL_NUMBER_OF (line), L"- %s\r\n", _app_get_region_title (REDUCT_MODIFIED_LIST));
			_r_str_append (buffer1, RTL_NUMBER_OF (buffer1), line);
		}

		if ((mask & REDUCT_STANDBY_LIST) == REDUCT_STANDBY_LIST)
		{
			_r_str_printf (line, RTL_NUMBER_OF (line), L"- %s\r\n", _app_get_region_title (REDUCT_STANDBY_LIST));
			_r_str_append (buffer1, RTL_NUMBER_OF (buffer1), line);
		}

		if ((mask & REDUCT_STANDBY_PRIORITY0_LIST) == REDUCT_STANDBY_PRIORITY0_LIST)
		{
			_r_str_printf (line, RTL_NUMBER_OF (line), L"- %s\r\n", _app_get_region_title (REDUCT_STANDBY_PRIORITY0_LIST));
			_r_str_append (buffer1, RTL_NUMBER_OF (buffer1), line);
		}

		if ((mask & REDUCT_REGISTRY_CACHE) == REDUCT_REGISTRY_CACHE)
		{
			_r_str_printf (line, RTL_NUMBER_OF (line), L"- %s\r\n", _app_get_region_title (REDUCT_REGISTRY_CACHE));
			_r_str_append (buffer1, RTL_NUMBER_OF (buffer1), line);
		}

		if ((mask & REDUCT_COMBINE_MEMORY_LISTS) == REDUCT_COMBINE_MEMORY_LISTS)
		{
			_r_str_printf (line, RTL_NUMBER_OF (line), L"- %s\r\n", _app_get_region_title (REDUCT_COMBINE_MEMORY_LISTS));
			_r_str_append (buffer1, RTL_NUMBER_OF (buffer1), line);
		}

		StrTrimW (buffer1, L"\r\n");

		if (!_r_show_confirmmessage (hwnd, _r_locale_getstring (IDS_QUESTION), buffer1, L"IsShowReductConfirmation", FALSE))
			return;
	}

	_app_memory_reset_results ();

	SetCursor (LoadCursorW (NULL, IDC_WAIT));

	reduct_before = _app_getmemoryinfo (&mem_info);

	if ((mask & REDUCT_WORKING_SET) == REDUCT_WORKING_SET)
	{
		command = MemoryEmptyWorkingSets;

		status = NtSetSystemInformation (SystemMemoryListInformation, &command, sizeof (SYSTEM_MEMORY_LIST_COMMAND));

		_app_memory_record_result (REGION_WORKING_SET, status, TRUE);

		if (!NT_SUCCESS (status))
			_r_log (LOG_LEVEL_ERROR, NULL, L"NtSetSystemInformation", status, L"MemoryEmptyWorkingSets");
	}
	else
	{
		_app_memory_record_result (REGION_WORKING_SET, STATUS_SUCCESS, FALSE);
	}

	if ((mask & REDUCT_SYSTEM_FILE_CACHE) == REDUCT_SYSTEM_FILE_CACHE)
	{
		sfci.MinimumWorkingSet = MAXSIZE_T;
		sfci.MaximumWorkingSet = MAXSIZE_T;

		status = NtSetSystemInformation (SystemFileCacheInformationEx, &sfci, sizeof (SYSTEM_FILECACHE_INFORMATION));

		_app_memory_record_result (REGION_SYSTEM_FILE_CACHE, status, TRUE);

		if (!NT_SUCCESS (status))
			_r_log (LOG_LEVEL_ERROR, NULL, L"NtSetSystemInformation", status, L"SystemFileCacheInformation");
	}
	else
	{
		_app_memory_record_result (REGION_SYSTEM_FILE_CACHE, STATUS_SUCCESS, FALSE);
	}

	if ((mask & REDUCT_MODIFIED_FILE_CACHE) == REDUCT_MODIFIED_FILE_CACHE)
	{
		status = _app_flushvolumecache ();

		_app_memory_record_result (REGION_MODIFIED_FILE_CACHE, status, TRUE);

		if (!NT_SUCCESS (status))
			_r_log (LOG_LEVEL_ERROR, NULL, L"FlushVolumeCache", status, L"ModifiedFileCacheFlush");
	}
	else
	{
		_app_memory_record_result (REGION_MODIFIED_FILE_CACHE, STATUS_SUCCESS, FALSE);
	}

	if ((mask & REDUCT_MODIFIED_LIST) == REDUCT_MODIFIED_LIST)
	{
		command = MemoryFlushModifiedList;

		status = NtSetSystemInformation (SystemMemoryListInformation, &command, sizeof (SYSTEM_MEMORY_LIST_COMMAND));

		_app_memory_record_result (REGION_MODIFIED_LIST, status, TRUE);

		if (!NT_SUCCESS (status))
			_r_log (LOG_LEVEL_ERROR, NULL, L"NtSetSystemInformation", status, L"MemoryFlushModifiedList");
	}
	else
	{
		_app_memory_record_result (REGION_MODIFIED_LIST, STATUS_SUCCESS, FALSE);
	}

	if ((mask & REDUCT_STANDBY_LIST) == REDUCT_STANDBY_LIST)
	{
		command = MemoryPurgeStandbyList;

		status = NtSetSystemInformation (SystemMemoryListInformation, &command, sizeof (SYSTEM_MEMORY_LIST_COMMAND));

		_app_memory_record_result (REGION_STANDBY_LIST, status, TRUE);

		if (!NT_SUCCESS (status))
			_r_log (LOG_LEVEL_ERROR, NULL, L"NtSetSystemInformation", status, L"MemoryPurgeStandbyList");
	}
	else
	{
		_app_memory_record_result (REGION_STANDBY_LIST, STATUS_SUCCESS, FALSE);
	}

	if ((mask & REDUCT_STANDBY_PRIORITY0_LIST) == REDUCT_STANDBY_PRIORITY0_LIST)
	{
		command = MemoryPurgeLowPriorityStandbyList;

		status = NtSetSystemInformation (SystemMemoryListInformation, &command, sizeof (SYSTEM_MEMORY_LIST_COMMAND));

		_app_memory_record_result (REGION_STANDBY_PRIORITY0, status, TRUE);

		if (!NT_SUCCESS (status))
			_r_log (LOG_LEVEL_ERROR, NULL, L"NtSetSystemInformation", status, L"MemoryPurgeLowPriorityStandbyList");
	}
	else
	{
		_app_memory_record_result (REGION_STANDBY_PRIORITY0, STATUS_SUCCESS, FALSE);
	}

	if (_r_sys_isosversiongreaterorequal (WINDOWS_8_1))
	{
		if ((mask & REDUCT_REGISTRY_CACHE) == REDUCT_REGISTRY_CACHE)
		{
			status = NtSetSystemInformation (SystemRegistryReconciliationInformation, NULL, 0);

			_app_memory_record_result (REGION_REGISTRY_CACHE, status, TRUE);

			if (!NT_SUCCESS (status))
				_r_log (LOG_LEVEL_ERROR, NULL, L"NtSetSystemInformation", status, L"SystemRegistryReconciliationInformation");
		}
		else
		{
			_app_memory_record_result (REGION_REGISTRY_CACHE, STATUS_SUCCESS, FALSE);
		}
	}
	else
	{
		if ((mask & REDUCT_REGISTRY_CACHE) == REDUCT_REGISTRY_CACHE)
			_app_memory_record_skip (REGION_REGISTRY_CACHE);
		else
			_app_memory_record_result (REGION_REGISTRY_CACHE, STATUS_SUCCESS, FALSE);
	}

	if (_r_sys_isosversiongreaterorequal (WINDOWS_10))
	{
		if ((mask & REDUCT_COMBINE_MEMORY_LISTS) == REDUCT_COMBINE_MEMORY_LISTS)
		{
			status = NtSetSystemInformation (SystemCombinePhysicalMemoryInformation, &combine_info_ex, sizeof (MEMORY_COMBINE_INFORMATION_EX));

			_app_memory_record_result (REGION_COMBINE_MEMORY_LISTS, status, TRUE);

			if (!NT_SUCCESS (status))
				_r_log (LOG_LEVEL_ERROR, NULL, L"NtSetSystemInformation", status, L"SystemCombinePhysicalMemoryInformation");
		}
		else
		{
			_app_memory_record_result (REGION_COMBINE_MEMORY_LISTS, STATUS_SUCCESS, FALSE);
		}
	}
	else
	{
		if ((mask & REDUCT_COMBINE_MEMORY_LISTS) == REDUCT_COMBINE_MEMORY_LISTS)
			_app_memory_record_skip (REGION_COMBINE_MEMORY_LISTS);
		else
			_app_memory_record_result (REGION_COMBINE_MEMORY_LISTS, STATUS_SUCCESS, FALSE);
	}

	SetCursor (LoadCursorW (NULL, IDC_ARROW));

	reduct_after = _app_getmemoryinfo (&mem_info);

	if (reduct_after < reduct_before)
		reduct_after = (reduct_before - reduct_after);
	else
		reduct_after = 0;

	_r_config_setlong64 (L"StatisticLastReduct", _r_unixtime_now (), NULL);

	_r_format_bytesize64 (buffer1, RTL_NUMBER_OF (buffer1), reduct_after);

	_r_str_printf (buffer2, RTL_NUMBER_OF (buffer2), _r_locale_getstring (IDS_STATUS_CLEANED), buffer1);

	if (_app_memory_has_failed_regions ())
		flags = NIIF_ERROR;

	if (src == SOURCE_CMDLINE)
	{
		if (_r_config_getboolean (L"BalloonCleanResults", TRUE, NULL))
		{
			if (hwnd)
				_app_tray_popup (hwnd, flags, _r_app_getname (), buffer2);
			else
				_r_show_message (hwnd, MB_OK | MB_ICONINFORMATION, NULL, buffer2);
		}
		else
		{
			_r_show_message (hwnd, MB_OK | MB_ICONINFORMATION, NULL, buffer2);
		}
	}
	else
	{
		if (hwnd && _r_config_getboolean (L"BalloonCleanResults", TRUE, NULL))
			_app_tray_popup (hwnd, flags, _r_app_getname (), buffer2);
	}

	if (_r_config_getboolean (L"LogCleanResults", FALSE, NULL))
		_r_log_v (LOG_LEVEL_INFO, 0, _app_getcleanupreason (src), 0, buffer1);

	_app_memory_refresh_status_ui ();
}

BOOLEAN _app_memory_has_failed_regions ()
{
	for (ULONG i = 0; i < REGION_COUNT; i++)
	{
		if (cleanup_results[i].state == CLEANUP_STATE_FAILED)
			return TRUE;
	}

	return FALSE;
}

VOID _app_memory_populate_status_listview (
	_In_ HWND hwnd,
	_In_ INT ctrl_id
)
{
	WCHAR buffer[128];
	LPWSTR status_text;

	_r_listview_deleteallitems (hwnd, ctrl_id);

	for (ULONG i = 0; i < REGION_COUNT; i++)
	{
		switch (cleanup_results[i].state)
		{
			case CLEANUP_STATE_SUCCESS:
				status_text = _r_locale_getstring (IDS_CLEANUP_STATUS_OK);
				break;

			case CLEANUP_STATE_FAILED:
				_r_str_printf (buffer, RTL_NUMBER_OF (buffer), _r_locale_getstring (IDS_CLEANUP_STATUS_FAIL), (ULONG)cleanup_results[i].status);
				status_text = buffer;
				break;

			case CLEANUP_STATE_SKIPPED:
				status_text = _r_locale_getstring (IDS_CLEANUP_STATUS_SKIP);
				break;

			default:
				status_text = _r_locale_getstring (IDS_CLEANUP_STATUS_NONE);
				break;
		}

		_r_listview_additem (hwnd, ctrl_id, i, _app_memory_region_name ((CLEANUP_REGION_ENUM)i), I_DEFAULT, I_DEFAULT, I_DEFAULT);
		_r_listview_setitem (hwnd, ctrl_id, i, 1, status_text, I_DEFAULT, I_DEFAULT, I_DEFAULT);
	}
}

VOID _app_memory_refresh_status_ui ()
{
	HWND hsettings;
	HWND hpage = NULL;

	hsettings = _r_settings_getwindow ();

	if (!hsettings)
		return;

	EnumChildWindows (hsettings, &_app_memory_find_status_page, (LPARAM)&hpage);

	if (hpage)
		_app_memory_populate_status_listview (hpage, IDC_CLEANUP_STATUS);
}
