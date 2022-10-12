
local log = require "log"
local mqtt = require "mqtt"
local capabilities = require "st.capabilities"


-- function_codes['TEMP_PRESET']  = '179' # 17-32 degrees
-- function_codes['TEMP_INDOOR']  = '187'
-- function_codes['TEMP_OUTDOOR'] = '190'
-- function_codes['POWER_STATE']  = '128' = 0x80
-- function_codes['POWER_SEL']    = '135' # 50/75/100
-- function_codes['TIMER_ON']     = '144'
-- function_codes['TIMER_OFF']    = '148'
-- function_codes['FAN_MODE']     = '160'
-- function_codes['SWING_STATE']  = '163'
-- function_codes['UNIT_MODE']    = '176'
-- function_codes['SPECIAL_MODE'] = '247'

-- function_values = {}
-- function_values['POWER_STATE']  = {'0':'-', '48':'ON', '49':'OFF'}
-- function_values['FAN_MODE']     = {'0':'-', '49':'QUIET', '50':'1', '51':'2', '52':'3', '53':'4', '54':'5', '65':'AUTO'}
-- function_values['SWING_STATE']  = {'0':'-', '49':'OFF', '65':'ON'}
-- function_values['UNIT_MODE']    = {'0':'-', '65':'AUTO', '66':'COOL', '67':'HEAT', '68':'DRY', '69':'FAN'}
-- function_values['POWER_SEL']    = {'50':'50%', '75':'75%', '100':'100%'}
-- function_values['SPECIAL_MODE'] = {'0':'-', '1':'HIPOWER', '3':'ECO/CFTSLP', '4':'8C', '2':'SILENT-1', '10':'SILENT-2', '32':'FRPL1', '48':'FRPL2'}
-- function_values['TIMER_ON']     = {'65':'ON', '66':'OFF'}
-- function_values['TIMER_OFF']    = {'65':'ON', '66':'OFF'}
-- 
local command_buffer = {0x02, 0x00, 0x03, 0x10, 0x00, 0x00, 0x07, 0x01, 0x30, 0x01, 0x00, 0x02}

tasmota_driver = {
}

local function int_to_signed(val)
    if val > 127 then
        return (256 - val) * -1
    end
    return val
end

local function ac_checksum(h_v, l_v)
    -- sum command_buffer
    -- 0x02 + 0x00 + 0x03 + 0x10 + 0x00 + 0x00 + 0x07 + 0x01 + 0x30 + 0x01 + 0x00 + 0x02 = 0x50
    -- 020003100000070130010002 80 31 01 +
    -- 020003100000070130010002 80 30 02 +
    -- 
    local checksum = (434 - h_v - l_v) % 0x100
    log.debug("Checksum for command is: " .. tostring(checksum))
    return checksum
end

local function make_buffer(h_v, l_v)
    local checksum = ac_checksum(h_v, l_v)
    return {0x02, 0x00, 0x03, 0x10, 0x00, 0x00, 0x07, 0x01, 0x30, 0x01, 0x00, 0x02, h_v, l_v, checksum}
end

function tasmota_driver.send_command(device, h_v, l_v)
    local buffer = make_buffer(h_v, l_v)
    -- convert to hex string
    local command = ""
    for i=1, #buffer do
        command = command .. string.format("%02x", buffer[i])
    end
    log.debug("Sending command: " .. command)

    client:publish {
        topic = "cmnd/DVES_85CEA6_fb/SerialSend5",
        payload = command,
        qos = tonumber(device.preferences.cmdqos),
        retain = device.preferences.retain,
      }

    --mqtt.publish("cmnd/DVES_85CEA6_fb/SerialSend5", command)
end

function tasmota_driver.handle_switch(driver, device, command)
    log.debug ('AC switch command received:', command.command)

    -- if command.args.state == 'on' then 0x30 else 0x31 end
    tasmota_driver.send_command(device, 0x80, command.command == 'on' and 0x30 or 0x31)
end

function tasmota_driver.handle_set_temp(driver, device, command)
    log.debug ('AC set temp command received:', command.args.setpoint)


    local temp = math.floor(command.args.setpoint)
    tasmota_driver.send_command(device, 0xB3, temp)
end

function tasmota_driver.handle_set_fan(driver, device, command)
    log.debug ('AC set fan command received:', command.args.speed)

    -- 0 = Off, 1 = Low, 2 = Medium, 3 = High, 4 = Max
    -- 0x31 = QUIET, 0x32 = 1, 0x33 = 2, 0x34 = 3, 0x35 = 4, 0x36 = 5, 0x41 = AUTO
    local fan = 0x30 + command.args.speed

    if command.args.speed == 0 then
        fan = 0x41
    end

    tasmota_driver.send_command(device, 0xA0, fan)
end

function tasmota_driver.handle_set_mode(driver, device, command)
    log.debug ('AC set mode command received:', command.args.mode)

    -- 0x41 = AUTO, 0x42 = COOL, 0x43 = HEAT, 0x44 = DRY, 0x45 = FAN
    local mode
    if command.args.mode == 'off' then
        --device:emit_event(capabilities.switch.switch("off"))
        tasmota_driver.send_command(device, 0x80, 0x31)
    else
        tasmota_driver.send_command(device, 0x80, 0x30)
        --device:emit_event(capabilities.switch.switch(command.on))
        
        if command.args.mode == 'auto' then
            mode = 0x41
        elseif command.args.mode == 'cool' then
            mode = 0x42
        elseif command.args.mode == 'heat' then
            mode = 0x43
        elseif command.args.mode == 'dryair' then
            mode = 0x44
        elseif command.args.mode == 'fanonly' then
            mode = 0x45
        end

        tasmota_driver.send_command(device, 0xB0, mode)
    end
end

function tasmota_driver.handle_special_mode(driver, device, command)
    log.debug ('AC set special mode command received:', command.args.mode)

    -- 0x01 = HIPOWER, 0x03 = ECO/CFTSLP, 0x04 = 8C, 0x02 = SILENT-1, 0x0A = SILENT-2, 0x20 = FRPL1, 0x30 = FRPL2
    local mode = command.args.mode
    tasmota_driver.send_command(device, 0xF7, mode)
end

function tasmota_driver.handle_set_power_sel(driver, device, command)
    log.debug ('AC set power command received:', command.args.power)

    -- 0x32 = 50%, 0x33 = 75%, 0x34 = 100%
    local power = 0x30 + command.args.power
    tasmota_driver.send_command(device, 0x87, power)
end

function tasmota_driver.handle_set_swing(driver, device, command)
    log.debug ('AC set swing command received:', command.args.fanOscillationMode)

    -- 0x41 = swing, 0x31 = fixed
    local swing = command.args.fanOscillationMode == 'vertical' and 0x41 or 0x31
    tasmota_driver.send_command(device, 0xA3, swing)
end

-- tasmota_driver.handle_set_timer_on(driver, device, command)
--     log.debug ('AC set timer on command received:', command.args.timer_on)

--     -- 0x41 = ON, 0x42 = OFF
--     local timer_on = command.args.timer_on == 'on' and 0x41 or 0x42
--     send_command(device, "SerialSend5", make_buffer( 0x90, timer_on) )
-- end

-- tasmota_driver.handle_set_timer_off(driver, device, command)
--     log.debug ('AC set timer off command received:', command.args.timer_off)

--     -- 0x41 = ON, 0x42 = OFF
--     local timer_off = command.args.timer_off == 'on' and 0x41 or 0x42
--     send_command(device, "SerialSend5", make_buffer( 0x98, timer_off) )
-- end

-- tasmota_driver.handle_set_timer_on_time(driver, device, command)
--     log.debug ('AC set timer on time command received:', command.args.timer_on_time)

--     -- 0x00 = 00:00, 0x01 = 01:00, 0x02 = 02:00, ..., 0x17 = 23:00
--     local timer_on_time = command.args.timer_on_time
--     send_command(device, "SerialSend5", make_buffer( 0x91, timer_on_time) )
-- end

-- tasmota_driver.handle_set_timer_off_time(driver, device, command)
--     log.debug ('AC set timer off time command received:', command.args.timer_off_time)

--     -- 0x00 = 00:00, 0x01 = 01:00, 0x02 = 02:00, ..., 0x17 = 23:00
--     local timer_off_time = command.args.timer_off_time
--     send_command(device, "SerialSend5", make_buffer( 0x99, timer_off_time) )
-- end

function tasmota_driver.is_tasmota(device)
    -- MQTT_airconditioner/tasmota_1665570745.763
    log.debug("Checking if device is AC", device.device_network_id)
    return device.device_network_id:match('MQTT_airconditioner/tasmota_')
end



return tasmota_driver