# shellcheck shell=bash
# shellcheck disable=SC2034 # the M_* variables are used by the other dm libraries
# Spanish (a key missing here falls back to English) catalog. Formats use printf placeholders (%s); see dm_i18n_load in dm_core.sh.
M_UPDATING='Actualizando devmesh a %s…\n'

# Claude sessions panel (dm-tui).
M_PW_CONFIRM_OFF='%s solo se podrá volver a encender con su botón de encendido. ¿Apagar?'
M_PW_DONE_SUSPEND='suspendiendo %s…'
M_PW_DONE_OFF='apagando %s…'
M_PW_DONE_WAKE='despertar enviado a %s'
M_PW_E_FAILED='la máquina no lo hizo'
M_PW_E_NOT_ALLOWED='esta máquina no lo permite (ejecuta dm update en ella)'
M_PW_E_UNSUPPORTED='no disponible en esta máquina'
M_PW_WHY_OTHER_LAN='Desde aquí no se podría despertar: está en otra red'
M_PW_WHY_NO_RELAY='Ninguna otra máquina de su red está en línea para despertarla'
M_PW_WHY_NO_MAC='No tiene MAC registrada, no se podría despertar'
M_PW_WHY_NO_WOL='No se podría despertar: Wake-on-WLAN no está activo en ella'
M_PW_WHY_OUTDATED='Primero ejecuta dm update en esa máquina'
M_PW_WHY_NO_POWER='Esa máquina no lo permite (ejecuta dm update en ella)'
M_PW_WHY_UNSUPPORTED='No disponible para este dispositivo'
M_PW_WHY_SELF='Es la máquina donde estás'
M_PW_WHY_OK='Nada que hacer'
M_PW_STATE_ON='%s está encendida'
M_PW_STATE_OFF='%s está apagada o dormida'
M_PW_CAN='se puede: %s'
