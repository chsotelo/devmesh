# shellcheck shell=bash
# shellcheck disable=SC2034 # the M_* variables are used by the other dm libraries
# English (reference: every key lives here) catalog. Formats use printf placeholders (%s); see dm_i18n_load in dm_core.sh.
M_UPDATING='Updating devmesh to %s…\n'

# Claude sessions panel (dm-tui).
M_PW_CONFIRM_OFF='%s can only be turned on again with its power button. Power it off?'
M_PW_DONE_SUSPEND='suspending %s…'
M_PW_DONE_OFF='powering off %s…'
M_PW_DONE_WAKE='wake-up sent to %s'
M_PW_E_FAILED='the machine did not do it'
M_PW_E_NOT_ALLOWED='this machine does not allow it (run dm update on it)'
M_PW_E_UNSUPPORTED='not available on this machine'
M_PW_WHY_OTHER_LAN='It could not be woken from here: it is on another network'
M_PW_WHY_NO_RELAY='No other machine is online on its network to wake it'
M_PW_WHY_NO_MAC='It has no MAC address registered, so it could not be woken'
M_PW_WHY_NO_WOL='It could not be woken: Wake-on-WLAN is not active on it'
M_PW_WHY_OUTDATED='Run dm update on that machine first'
M_PW_WHY_NO_POWER='That machine does not allow it (run dm update on it)'
M_PW_WHY_UNSUPPORTED='Not available for this device'
M_PW_WHY_SELF='This is the machine you are on'
M_PW_WHY_OK='Nothing to do'
M_PW_STATE_ON='%s is on'
M_PW_STATE_OFF='%s is off or asleep'
M_PW_CAN='can: %s'
