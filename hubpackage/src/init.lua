--[[
  Copyright 2021 Todd Austin

  Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file
  except in compliance with the License. You may obtain a copy of the License at:

      http://www.apache.org/licenses/LICENSE-2.0

  Unless required by applicable law or agreed to in writing, software distributed under the
  License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
  either express or implied. See the License for the specific language governing permissions
  and limitations under the License.


  DESCRIPTION
  
  MQTT Device Handler Driver

--]]

-- Edge libraries
local capabilities = require "st.capabilities"
local TemperatureMeasurement    = capabilities.temperatureMeasurement
local ThermostatCoolingSetpoint = capabilities.thermostatCoolingSetpoint
local ThermostatHeatingSetpoint = capabilities.thermostatHeatingSetpoint
local ThermostatMode            = capabilities.thermostatMode
local ThermostatFanMode         = capabilities.thermostatFanMode
local ThermostatOperatingState  = capabilities.thermostatOperatingState
local FanSpeed                  = capabilities.fanSpeed
local FanOscillationMode        = capabilities.fanOscillationMode
local DishwasherOperatingState  = capabilities.dishwasherOperatingState

---
local Driver = require "st.driver"
local cosock = require "cosock"
local socket = require "cosock.socket"          -- just for time
local os     = require "os"
--local Thread = require "st.thread"
local log = require "log"

local mqtt = require "mqtt"

-- Global variables
thisDriver = {}

client = nil
client_reset_inprogress = false

-- Module variables
local config_initialized = false

local TOPIC_PREFIX = 'smartthings'
local SUBSCRIBE_TOPIC = 'smartthings/#'


-- Custom Capabilities
local cap_status                = capabilities["partyvoice23922.status"]
local cap_refresh               = capabilities["partyvoice23922.refresh"]
local DishwasherMode            = capabilities.dishwasherMode --["winterdictionary35590.dishwasherMode"]
local DishwasherBaskets         = capabilities["winterdictionary35590.dishwasherbaskets"]          
local CoffeeBrew                = capabilities["winterdictionary35590.coffeebrew"]          
local CoffeeWater               = capabilities["winterdictionary35590.coffeewater"]
local CoffeeStength             = capabilities["winterdictionary35590.coffeestrength2"]
local FanSpeed2                 = capabilities["winterdictionary35590.fanspeed"]

--local CoffeeState               = capabilities["winterdictionary35590.coffeemakeroperatingstate"]


local function disptable(table, tab, maxlevels, currlevel)

	if not currlevel then; currlevel = 0; end
  currlevel = currlevel + 1
  for key, value in pairs(table) do
    if type(key) ~= 'table' then
      log.debug (tab .. '  ' .. key, value)
    else
      log.debug (tab .. '  ', key, value)
    end
    if (type(value) == 'table') and (currlevel < maxlevels) then
      disptable(value, '  ' .. tab, maxlevels, currlevel)
    end
  end
end


local profiles =  {
                    ['mqttdisco']      = 'mqttconfig.v1',
                    ['switch']         = 'mqttswitch.v1',
                    ['plug']           = 'mqttplug.v1',
                    ['light']          = 'mqttlight.v1',
                    ['momentary']      = 'mqttmomentary.v1',
                    ['button']         = 'mqttmomentary.v1',
                    ['motion']         = 'mqttmotion.v1',
                    ['motionSensor']   = 'mqttmotion.v1',
                    ['presence']       = 'mqttpresence.v1',
                    ['presenceSensor'] = 'mqttpresence.v1',
                    ['contact']        = 'mqttcontact.v1',
                    ['contactSensor']  = 'mqttcontact.v1',
                    ['temperature']    = 'mqtttemp.v1',
                    ['temperatureMeasurement']    = 'mqtttemp.v1',
                    ['alarm']          = 'mqttalarm.v1',
                    ['switchLevel']    = 'mqttlevel.v1',
                    ['level']          = 'mqttlevel.v1',
                    ['dimmer']         = 'mqttlevel.v1',
                    ['valve']          = 'mqttvalve.v1',

                    ['airconditioner'] = 'mqttairconditioner.v1',
                    ['coffee']         = 'mqttcoffeemaker.v1',
                    ['dishwasher']     = 'mqttdishwasher.v1',
                    ['sensor']         = 'mqttco2.v1',
                  }


local function create_device(driver, topic)

  local MFG_NAME = 'SmartThings Community'
  local MODEL = topic.profile
  local VEND_LABEL = topic.name
  local ID = 'MQTT_' .. topic.path .. '_' .. socket.gettime()
  
  local PROFILE = profiles[topic.profile]
  
  log.info (string.format('Creating new device: label=<%s>, id=<%s>', VEND_LABEL, ID))

  local create_device_msg = {
                              type = "LAN",
                              device_network_id = ID,
                              label = VEND_LABEL,
                              profile = PROFILE,
                              manufacturer = MFG_NAME,
                              model = MODEL,
                              vendor_provided_label = VEND_LABEL,
                            }
                      
  assert (driver:try_create_device(create_device_msg), "failed to create device")
end


local function determine_device(topic)
  if topic.name == nil then
    return nil
  end

  local device_list = thisDriver:get_devices()
  
  for _, device in ipairs(device_list) do
    if device.device_network_id:find(topic.name, 1, 'plaintext') then; return device; end
  end

end


local function proc_config(topic, msg)

  if not determine_device(topic) then
  
    create_device(thisDriver, topic)
    
  end

end


local function validate_state(capattr, statevalue)

  for key, value in pairs(capattr) do
    if type(value) == 'table' then
      for key2, value2 in pairs(value) do
        if key2 == 'attribute' then
          if key == statevalue then
            return (true)
          end
        end
      end
    end
  end
  
  log.warn (string.format('Invalid state value [%s] received for %s', statevalue, capattr.NAME))
  return false

end


local function try_emit(device, capattr, state)
  if validate_state(capattr, state) then
    device:emit_event(capattr(state))
  end
end


local function proc_state(topic, state)

  local device = determine_device(topic)
  
  log.debug (string.format('Device name <%s> sent updated state value = "%s"', topic.name, state))
  
  if device == nil then
    log.warn('Unrecognized device; message ignored <'.. tostring( topic.name ) .. '> cap:"' .. tostring( topic.cap ) .. '"')
  else
    if topic.cap == 'mode' then
      if topic.profile == 'airconditioner' then
        -- device:emit_event(capabilities.airConditionerMode.airConditionerMode(state))
        device:emit_event( ThermostatMode.thermostatMode(state) )
        if state ~= 'off' then
          device:set_field('thermostatMode', state )
        end
      elseif topic.profile == 'dishwasher' then
        try_emit(device, capabilities.dishwasherMode.dishwasherMode, state)
      end
    elseif topic.cap == 'brew' then
      if state == nil or state == '' then
        device:emit_event( CoffeeBrew.brew("Select") )
      else
        device:emit_event( CoffeeBrew.brew(state) )
      end
      ---
    elseif topic.cap == 'water_level' and state ~= nil then
      local water_level = tonumber(state)
      device:emit_event( CoffeeWater.waterLevel({ value= water_level }))
      
    elseif topic.cap == 'strength_level' and state ~= nil then
      local strength = tonumber(state)
      device:emit_event( CoffeeStength.strength({ value = strength }))
      
    elseif topic.cap == 'status' then
      device:emit_event(cap_status.status(state))
      if topic.profile == 'coffee' then

        local _state = "idle"
        if state == 'off' then
          _state = 'powerOff'
        elseif state == 'ready' then
          _state = 'idle'
        elseif state == 'brewing' then
          _state = 'cleaning'
        end
        
        device:emit_event(capabilities.robotCleanerMovement.robotCleanerMovement({value=_state}))
      end  
    
    elseif topic.cap == 'water_hardness' then
      device:emit_event(cap_status.status(state))
      
    elseif topic.cap == "outdoortemp" then
      local temp = tonumber(state)
      if temp then
        if temp == 127 then
          --device:emit_component_event(device.profile.components["outdoor"], TemperatureMeasurement.temperature(-100))
        else
          device:emit_component_event(device.profile.components["outdoor"], TemperatureMeasurement.temperature(({ value = temp, unit = "C"}) ))
        end
      end
    
    elseif topic.cap == "setpoint" then
      local temp = tonumber(state)
      if temp then
        device:emit_event(ThermostatCoolingSetpoint.coolingSetpoint({value=temp, unit='C'}))
        device:emit_event(ThermostatHeatingSetpoint.heatingSetpoint({value=temp, unit='C'}))
      end

    elseif topic.cap == "fanmode" or topic.cap == "fan_mode" then
      
      if state == 'auto' then
        device:emit_event(FanSpeed.fanSpeed(0))
      elseif state == 'quiet' then
        device:emit_event(FanSpeed.fanSpeed(1))
      else 
        device:emit_event(FanSpeed.fanSpeed(tonumber(state)))
      end
  
    elseif topic.cap == 'swingmode' then
      local value = "fixed"
      if state == 'on' then
        value = "vertical"
      end
      device:emit_event(FanOscillationMode.fanOscillationMode(value))
  
    elseif topic.cap == 'switch' or topic.cap == 'plug' or topic.cap == 'light' then
    
      if validate_state(capabilities.switch.switch, state) then
        device:emit_event(capabilities.switch.switch(state))
      end
    
    elseif topic.cap == 'motion' or topic.cap == 'motionSensor' then
    
      if validate_state(capabilities.motionSensor.motion, state) then
        device:emit_event(capabilities.motionSensor.motion(state))
      end
    
    elseif topic.cap == 'presence' or topic.cap == 'presenceSensor' then
    
      if validate_state(capabilities.presenceSensor.presence, state) then
        device:emit_event(capabilities.presenceSensor.presence(state))
      end
    
    elseif topic.cap == 'contact' or topic.cap == 'contactSensor'then
      
      try_emit(device, capabilities.contactSensor.contact, state)
    
    elseif topic.cap == 'momentary' or topic.cap == 'button' then
    
      local supported_values =  {
                                  'pushed',
                                  'held',
                                  'double',
                                  'pushed_2x',
                                  'pushed_3x'
                                 }

      for _, val in ipairs(supported_values) do
        if state == val then
          device:emit_event(capabilities.button.button[state]({state_change = true}))
          break
        end
      end
      
    elseif topic.cap == 'temperature' or topic.cap == TemperatureMeasurement.NAME then
    
      local temp = tonumber(state)
      if temp then
        device:emit_event(TemperatureMeasurement.temperature(({ value = temp, unit = "C"}) ))
      end
    
    elseif topic.cap == 'alarm' then
      if validate_state(capabilities.alarm.alarm, state) then
        device:emit_event(capabilities.alarm.alarm(state))
      end
      
    elseif topic.cap == 'switchLevel' or topic.cap == 'level' or topic.cap == 'dimmer' then
      local level = tonumber(state)
      if level then
        device:emit_event(capabilities.switchLevel.level(level))
      end
    
    elseif topic.cap == 'pm10' then
      local pm10 = tonumber(state)
      if pm10 then
        device:emit_event(capabilities.dustSensor.dustLevel(pm10))
      end
    elseif topic.cap == 'pm2.5' then
      local pm25 = tonumber(state)
      if pm25 then
        device:emit_event(capabilities.dustSensor.fineDustLevel(pm25))
      end
    elseif topic.cap == 'ldr' then
      local illuminance = tonumber(state)
      if illuminance then
        device:emit_event(capabilities.illuminanceMeasurement.illuminance(illuminance))
      end

    elseif topic.cap == 'co2' then
      local co2 = tonumber(state)
      if co2 then
        device:emit_event(capabilities.carbonDioxideMeasurement.carbonDioxide({value=co2, unit='ppm'}))
        local airQuality = "good"
        if co2 > 5000 then
          airQuality = "hazardous"
        elseif co2 > 2500 then
          airQuality = "veryUnhealthy"
        elseif co2 > 2000 then
          airQuality = "unhealthy"
        elseif co2 > 1500 then
          airQuality = "slightlyUnhealthy"
        elseif co2 > 1000 then
          airQuality = "moderate"    
        end

        device:emit_event(capabilities.carbonDioxideHealthConcern.carbonDioxideHealthConcern(airQuality))
      end
    
    elseif topic.cap == 'state' then
      if topic.profile == 'dishwasher' then
        local machineState = "stop"
        if state == "pause" then
          machineState = "pause"
        elseif state:find("wash") ~= nil then
          machineState = "run"
        end
        
        device:emit_event(DishwasherOperatingState.machineState(machineState))
      end
    elseif topic.cap == 'job_state' then
      if topic.profile == 'dishwasher' then
        if state == 'ready' then state = 'finish' else state = 'wash' end
        device:emit_event(DishwasherOperatingState.dishwasherJobState(state))
      end
    elseif topic.cap == 'completion_min' then 
      -- if machineState == "run" then
      local epochSeconds = math.floor(os.time()) + (tonumber(state) * 60)
      local time = os.date("!%Y-%m-%dT%TZ", epochSeconds)
    
      log.debug('completion time: ' .. time)
      device:emit_event(DishwasherOperatingState.completionTime(time)) -- "2022-09-05T14:18:45Z" 

    elseif topic.cap == 'valve' then
      if validate_state(capabilities.valve.valve, state) then
        device:emit_event(capabilities.valve.valve(state))
      end
      
    else
      log.warn ('Unsupported capability:', topic.cap)
    end

  end

end


local function parse_topic(msgtopic)

  -- Topic format:  smartthings/<profile>/<unique_name>/<capabiltiy>

  local topic = {}
  local topic_parts = {}
  local i = 1
  
  for element in string.gmatch(msgtopic, "[^/]+") do
    topic_parts[i] = element
    i = i + 1
  end
  
  if #topic_parts < 4 then; return; end
  
  topic.prefix = topic_parts[1]
  topic.profile = topic_parts[2]
  topic.name = topic_parts[3]
  topic.cap = topic_parts[4]
  
  topic.path = msgtopic:match('smartthings/(.+)/%w+$')
  
  return topic

end


local function create_MQTT_client(driver, device)

	-- create mqtt client
  local connect_args = {}
  connect_args.uri = device.preferences.broker
  connect_args.clean = true
  connect_args.driver = driver
  connect_args.device = device
  
  if device.preferences.userid ~= '' and device.preferences.password ~= '' then
    if device.preferences.userid ~= 'xxxxx' and device.preferences.password ~= 'xxxxx' then
      connect_args.username = device.preferences.userid
      connect_args.password = device.preferences.password
    end
  end
  
  client = mqtt.client(connect_args)

  client:on{
    connect = function(connack)
      if connack.rc ~= 0 then
				log.error ("Connection to broker failed:", connack:reason_string(), connack)
      else
        log.info("Connected to MQTT broker:", connack) -- successful connection
        device:emit_event(cap_status.status('Connected to Broker'))
        
        -- subscribe to smartthings topic
        assert(client:subscribe{ topic=SUBSCRIBE_TOPIC, qos=tonumber(device.preferences.subqos), callback=function(suback)
          log.info("Subscribed to smartthings topic:", suback)
          device:emit_event(cap_status.status('Connected & Subscribed'))
        end})
        
      end

    end,

    message = function(msg)
      assert(client:acknowledge(msg))

      log.info("Received:", msg)
      -- example msg:  PUBLISH{payload="Hello world", topic="testmqtt/pimylifeup", dup=false, type=3, qos=0, retain=false}

      local topic = parse_topic(msg.topic)
      
      if topic then
      
        if topic.prefix ~= TOPIC_PREFIX then; return; end
        
        if topic.cap == 'config' then
          proc_config(topic, msg.payload)
          
        else --if topic.action == 'state' then
          proc_state(topic, msg.payload)
          
        end
      
      else
        log.warn ('Invalid topic structure received')
      end
      
    end,

    error = function(err)
      log.error("MQTT client error:", err)
      device:emit_event(cap_status.status(err))
    end,
  }

	return client

end


local function init_mqtt(driver, device)

  if device.preferences.broker == '192.168.1.xxx' then

      log.warn ('Broker address not initialized')
      return
  end

  if client then
    log.debug ('Unsubscribing and disconnecting current client...')
    local rc, err = client:unsubscribe{ topic=SUBSCRIBE_TOPIC, callback=function(unsuback)
				log.info("\t\tUnsubscribe callback:", unsuback)
      end}
      
    if rc == false then
			log.debug ('\tUnsubscribe failed with err:', err)
		else
			log.debug ('\tUnsubscribed')
		end
		
    rc, err = client:disconnect()
    if rc == false then
			log.debug ('\tDisconnect failed with err:', err)
		elseif rc == true then
			log.debug ('\tDisconnected')
		end
  end

  device:emit_event(cap_status.status('Connecting...'))

	client = create_MQTT_client(driver, device)

	-- Run MQTT loop in separate thread

  cosock.spawn(function()
		while true do
		  local ok, err = mqtt.run_sync(client)
		  
		  if ok == false then
        log.debug ('MQTT run_sync returned error:', err)
		    if string.lower(err):find('connection refused', 1, 'plaintext') or err == "closed" then
          log.debug ('client_reset_inprogress=', client_reset_inprogress)
					if client_reset_inprogress == true then; break; end
					
		      local connected = false
		      --client = nil
		      device:emit_event(cap_status.status('Reconnecting...'))
          
		      repeat
						-- create new mqtt client
						cosock.socket.sleep(15)
						if client_reset_inprogress == true then
							client_reset_inprogress = false
							return
						end
						log.info ('Attempting to reconnect to broker...')
						client = create_MQTT_client(driver, device)
					until client
					
				else
					break
				end
			else
				log.error ('Unexpected return from MQTT client:', ok, err)
			end
		end
	end, 'MQTT synch mode')	

end


local function init_devices()

  if client then
    
    log.debug ('Initializing device topic subscriptions')

    local device_list = thisDriver:get_devices()

    for _, device in ipairs(device_list) do

      local cap, name = device.device_network_id:match('MQTT_(%w+)_([%w%s_]+)_')
      
      if cap ~= 'config' then
      
        if not device:get_field('MQTT_subscribed') then
      
          local topic = 'smartthings/state/' .. cap .. '/' .. name
          assert(client:subscribe{ topic=topic, qos=1, callback=function(suback)
            log.info("Subscribed to device topic:", topic)
            device:set_field('MQTT_subscribed', true)
          end})
        end
      end
    end
  else
    log.error ('Cannot subscribe to device topics; broker not connected')
  end

end


local function send_command(device, topic, payload)

  if (device.preferences.cmdTopic ~= 'xxxxx/xxxxx') and (device.preferences.cmdTopic ~= nil) then
  
    if client then
    
      assert(client:publish {
                              topic = device.preferences.cmdTopic .. '/' .. topic,
                              payload = tostring(payload),
                              qos = tonumber(device.preferences.cmdqos),
                              retain = device.preferences.retain,
                            })
                            
      log.info ('Command published to', device.preferences.cmdTopic)
    end
  end

end




-----------------------------------------------------------------------
--											COMMAND HANDLERS
-----------------------------------------------------------------------

local function handle_refresh(driver, device, command)

  log.info ('Refresh requested')

	client_reset_inprogress = true
  init_mqtt(driver, device)
    
end


local function handle_switch(driver, device, command)

  log.info ('Switch command received:', command.command)
  
  device:emit_event(capabilities.switch.switch(command.command))
  send_command(device, "switch", command.command)

  local caps = device.st_store.profile.components.main.capabilities
  if caps.thermostatMode then
    mode = 'off'
    if command.command == 'on' then
      mode = device:get_field('thermostatMode')
    end
    send_command(device, "mode", mode)
  end
end

local function handle_level(driver, device, command)

  log.info ('Level set to:', command.args.level)
  
  device:emit_event(capabilities.switchLevel.level(command.args.level))
  
  send_command(device, command.command, command.args.level)
  
end

local function handle_valve(driver, device, command)

  log.info ('Valve command received:', command.command)
  
  if command.command == 'close' then
    device:emit_event(capabilities.valve.valve('closed'))
  elseif command.command == 'open' then
    device:emit_event(capabilities.valve.valve('open'))
  end
  
end

------------------------------------------------------------------------

local function handle_airconditioner_fan_mode(driver, device, command)

  log.info ('Air conditioner fan mode command received:', command.command)
  --device:emit_event(capabilities.airConditionerFanMode.airConditionerFanMode(command.command))
  send_command(device, command.command, command.command)
end

local function handle_airconditioner_mode(driver, device, command)

  log.info ('Air conditioner mode command received:', command.args.mode)
  --device:emit_event(capabilities.airConditionerMode.airConditionerMode(command.args.mode))
  send_command(device, "mode", command.args.mode)
end

local function handle_thermostat_heating_setpoint(driver, device, command)

  log.info ('Thermostat heating setpoint command received:', command.args.setpoint)
  --device:emit_event(ThermostatHeatingSetpoint.heatingSetpoint(command.args.setpoint))
  
  send_command(device, "setpoint", command.args.setpoint)
end

local function handle_thermostat_cooling_setpoint(driver, device, command)
  log.info ('Thermostat cooling setpoint command received:', command.args.setpoint)
  --device:emit_event(ThermostatCoolingSetpoint.coolingSetpoint(command.args.setpoint))
  send_command(device, "setpoint", command.args.setpoint)
end

local function handle_thermostat_mode(driver, device, command)
  log.info ('Thermostat mode command received:', command.args.mode)
  --device:emit_event(ThermostatMode.thermostatMode(command.args.mode))  
  send_command(device, "mode", command.args.mode)
end

local function handle_fan_oscillation_mode(driver, device, command)
  log.info ('Fan oscillation mode command received:', command.args.fanOscillationMode)
  --device:emit_event(FanOscillationMode.fanOscillationMode(command.args.fanOscillationMode))
  local swing = command.args.fanOscillationMode == 'vertical' and 'on' or 'off'
    
  send_command(device, "swingmode", swing)
end

local function handle_fan_speed(driver, device, command)
  log.info ('Fan speed command received:', command.args.speed)
  --device:emit_event(FanSpeed.fanSpeed(command.args.speed))
  
  local speed = tostring(command.args.speed)
  if command.args.speed == 0 then
    speed = 'auto'
  elseif command.args.speed == 1 then
    speed = 'quiet'
  end

  send_command(device, "fanmode", speed)
  --device:emit_event(FanSpeed2.fanSpeed(command.args.speed))
end
------------------------------------------------------------------------

local function handle_dishwasher_mode(driver, device, command)
  log.debug ('Dishwasher mode command received:', command.args.mode)
  send_command(device, "mode", command.args.mode)
end

local function handle_dishwasher_operating_state(driver, device, command)
  log.debug ('Dishwasher operating state command received:', command.args.state)
  send_command(device, "state", command.args.state)
end

local function handle_dishwasher_baskets(driver, device, command)
  log.debug ('Dishwasher baskets command received:', command.args.value)
  send_command(device, "baskets", command.args.value)
end

local function handle_coffee_strength(driver, device, command)
  log.debug ('Coffee strength command received:', command.args.value)
  send_command(device, "strength_level", command.args.value)
end

local function handle_water_level(driver, device, command)
  log.debug ('Water level command received:', command.args.value)
  send_command(device, "water_level", command.args.value)
end

local function handle_coffee_brew(driver, device, command)
  log.debug ('Coffee brew received:', command.args.value)
  send_command(device, "brew", command.args.value)
end

local function handle_coffee_operating_state(driver, device, command)
  log.debug ('Coffee operating state command received:', command.args.mode)
  send_command(device, "state", command.args.mode)
end


------------------------------------------------------------------------
--                REQUIRED EDGE DRIVER HANDLERS
------------------------------------------------------------------------

-- Lifecycle handler to initialize existing devices AND newly discovered devices
local function device_init(driver, device)
  
  log.debug(device.id .. ": " .. device.device_network_id .. "> INITIALIZING")
  
  if device.device_network_id:find('mqttdisco', 1, 'plaintext') then
    init_mqtt(driver, device)
    config_initialized = true
  end
  
end


-- Called when device was just created in SmartThings
local function device_added (driver, device)

  log.info(device.id .. ": " .. device.device_network_id .. "> ADDED")
  
  if not device.device_network_id:find("mqttdisco", 1, 'plaintext') then
  
    local caps = device.st_store.profile.components.main.capabilities
    
    for _, cap in pairs(caps) do
    
      if cap.id == 'switch' then
        device:emit_event(capabilities.switch.switch('off'))
      elseif cap.id == 'motionSensor' then
        device:emit_event(capabilities.motionSensor.motion('inactive'))
      elseif cap.id == 'presenceSensor' then
        device:emit_event(capabilities.presenceSensor.presence('not present'))
      elseif cap.id == 'contactSensor' then
        device:emit_event(capabilities.contactSensor.contact('closed'))
      elseif cap.id == 'momentary' then
        local supported_values =  {
                                    capabilities.button.button.pushed.NAME,
                                    capabilities.button.button.held.NAME,
                                    capabilities.button.button.double.NAME,
                                    capabilities.button.button.pushed_2x.NAME,
                                    capabilities.button.button.pushed_3x.NAME,
                                  }
        device:emit_event(capabilities.button.supportedButtonValues(supported_values))
        
      elseif cap.id == TemperatureMeasurement.ID then
        device:emit_event(capabilities.temperatureMeasurement.temperature({value=20, unit='C'}))
      elseif cap.id == 'alarm' then
        device:emit_event(capabilities.alarm.alarm('off'))
      elseif cap.id == 'switchLevel' then
        device:emit_event(capabilities.switchLevel.level(0))
      elseif cap.id == 'dustSensor' then
        device:emit_event(capabilities.dustSensor.dustLevel({value=0}))
        device:emit_event(capabilities.dustSensor.fineDustLevel({value=0}))
      elseif cap.id == 'carbonDioxideMeasurement' then
        device:emit_event(capabilities.carbonDioxideMeasurement.carbonDioxideMeasurement({value=400, unit='ppm'}))
        device:emit_event(capabilities.carbonDioxideHealthConcern.carbonDioxideHealthConcern("good"))
      elseif cap.id == 'valve' then
        device:emit_event(capabilities.valve.valve('closed'))
      ---
      elseif cap.id == 'dishwasherOperatingState' then
        device:emit_event(capabilities.dishwasherOperatingState.dishwasherJobState("finish"))
      elseif cap.id == DishwasherMode.ID then
        device:emit_event(DishwasherMode.dishwasherMode("auto"))
      ---
      elseif cap.id == 'airConditionerFanMode' then
        local supportedAcFanModes = {
          "auto", "quiet", "lvl_1", "lvl_2", "lvl_3", "lvl_4", "lvl_5"
        }
        device:emit_event(capabilities.airConditionerFanMode.supportedAcFanModes(supportedAcFanModes))
        device:emit_event(capabilities.airConditionerFanMode.setFanMode("auto"))
      elseif cap.id == 'airConditionerMode' then
        local supportedAcModes = {
          "cool", "dry", "heat", "auto", "fan"
        }
        device:emit_event(capabilities.airConditionerMode.supportedAcModes(supportedAcModes))
        device:emit_event(capabilities.airConditionerMode.airConditionerMode("auto"))
      ---
      elseif cap.id == ThermostatCoolingSetpoint.ID then
        device:emit_event(ThermostatCoolingSetpoint.coolingSetpoint({value=20, unit='C'}))
      elseif cap.id == ThermostatHeatingSetpoint.ID then
        device:emit_event(ThermostatHeatingSetpoint.heatingSetpoint({value=20, unit='C'}))
      elseif cap.id == ThermostatMode.thermostatMode.ID then
        local supportedThermostatModes = {
          ThermostatMode.thermostatMode.off.NAME, ThermostatMode.thermostatMode.auto.NAME, 
          ThermostatMode.thermostatMode.cool.NAME, ThermostatMode.thermostatMode.heat.NAME, 
          ThermostatMode.thermostatMode.dryair.NAME, ThermostatMode.thermostatMode.fanonly.NAME,
        }
        device:emit_event(ThermostatMode.supportedThermostatModes(supportedThermostatModes))
        device:emit_event(ThermostatMode.thermostatMode(ThermostatMode.thermostatMode.auto.NAME))
      elseif cap.id == ThermostatOperatingState.ID then
        device:emit_event(ThermostatOperatingState.thermostatOperatingState.idle())
        -- device:emit_event(ThermostatOperatingState.thermostatOperatingState.fan_only())
      elseif cap.id == ThermostatFanMode.ID then
        local supportedModes = { ThermostatFanMode.thermostatFanMode.auto.NAME, ThermostatFanMode.thermostatFanMode.on.NAME }
        device:emit_event(ThermostatFanMode.supportedThermostatFanModes(supportedModes))
        device:emit_event(ThermostatFanMode.thermostatFanMode(supportedFanModes[1]))
      ---
      elseif cap.id == FanSpeed.ID then
        device:emit_event(FanSpeed.fanSpeed(1))
      elseif cap.id == FanOscillationMode.ID then
        local supportedModes = { "vertical", "fixed" }
        device:emit_event(FanOscillationMode.supportedFanOscillationModes(supportedModes))
        device:emit_event(FanOscillationMode.fanOscillationMode("fixed"))
      end
      
    end
  end
  
end


-- Called when SmartThings thinks the device needs provisioning
local function device_doconfigure (_, device)

  log.info ('Device doConfigure lifecycle invoked')

end


-- Called when device was deleted via mobile app
local function device_removed(_, device)
  
  log.warn(device.id .. ": " .. device.device_network_id .. "> removed")
  
  local device_list = thisDriver:get_devices()
  
  if #device_list == 0 then
  
    if client then
    
      client:unsubscribe{ topic=SUBSCRIBE_TOPIC, callback=function(unsuback)
				log.info("Unsubscribed")
      end}
      client:disconnect()
      log.info("Disconnected from broker")
    end
    
  end
  
end


local function handler_driverchanged(driver, device, event, args)

  log.debug ('*** Driver changed handler invoked ***')

end


local function shutdown_handler(driver, event)

  log.info ('*** Driver being shut down ***')
  
  if client then
    
    client:unsubscribe{ topic=SUBSCRIBE_TOPIC, callback=function(unsuback)
      log.info("\tUnsubscribed from " .. SUBSCRIBE_TOPIC)
    end}
    client_reset_inprogress = true
    client:disconnect()
    
    log.info("\tDisconnected from MQTT broker")
  end

end


local function handler_infochanged (driver, device, event, args)

  log.debug ('Info changed handler invoked')

  -- Did preferences change?
  if args.old_st_store.preferences then
    
		if args.old_st_store.preferences.broker ~= device.preferences.broker then
      log.info ('Broker URI changed to: ', device.preferences.broker)
    elseif args.old_st_store.preferences.cmdTopic ~= device.preferences.cmdTopic then
      log.info (string.format('Device <%s> command topic changed to: %s', device.label, device.preferences.cmdTopic))
    elseif args.old_st_store.preferences.userid ~= device.preferences.userid then
      log.info ('Broker authentication userid changed to: ', device.preferences.userid)
    elseif args.old_st_store.preferences.password ~= device.preferences.password then
      log.info ('Broker authentication password changed to: ', device.preferences.password)
    elseif args.old_st_store.preferences.subqos ~= device.preferences.subqos then
      log.info ('Subscription QoS changed to: ', device.preferences.subqos)
    elseif args.old_st_store.preferences.retain ~= device.preferences.retain then
      log.info ('Retain option changed to: ', device.preferences.retain, type(device.preferences.retain))
    elseif args.old_st_store.preferences.cmdqos ~= device.preferences.cmdqos then
      log.info ('Command QoS changed to: ', device.preferences.cmdqos)
    end

  end
end


local function discovery_handler(driver, _, should_continue)
  
  if not config_initialized then
  
    log.info("Creating MQTT config device")
    
    create_device(driver, parse_topic('smartthings/mqttdisco/MQTT Discovery/config'))
    
  end
  
  log.debug("Exiting device creation")
end


-----------------------------------------------------------------------
--        DRIVER MAINLINE: Build driver context table
-----------------------------------------------------------------------
thisDriver = Driver("thisDriver", {
  discovery = discovery_handler,
  lifecycle_handlers = {
    init = device_init,
    added = device_added,
    driverSwitched = handler_driverchanged,
    infoChanged = handler_infochanged,
    doConfigure = device_doconfigure,
    removed = device_removed
  },
  driver_lifecycle = shutdown_handler,
  capability_handlers = {
  	[cap_refresh.ID] = {
      [cap_refresh.commands.push.NAME] = handle_refresh,
    },
    [capabilities.switch.ID] = {
      [capabilities.switch.commands.on.NAME] = handle_switch,
      [capabilities.switch.commands.off.NAME] = handle_switch,
    },
    [capabilities.switchLevel.ID] = {
      [capabilities.switchLevel.commands.setLevel.NAME] = handle_level,
    },
    [capabilities.valve.ID] = {
      [capabilities.valve.commands.close.NAME] = handle_valve,
      [capabilities.valve.commands.open.NAME] = handle_valve,
    },

    [ThermostatCoolingSetpoint.ID] = {
      ["setCoolingSetpoint"] = handle_thermostat_cooling_setpoint,
    },
    [ThermostatHeatingSetpoint.ID] = {
      ["setHeatingSetpoint"] = handle_thermostat_heating_setpoint,
    },

    [capabilities.airConditionerMode.ID] = {
      ["setAirConditionerMode"] = handle_airconditioner_mode,
    },
    [capabilities.airConditionerFanMode.ID] = {
      ["setAirConditionerFanMode"] = handle_airconditioner_fan_mode,
    },

    [capabilities.dishwasherMode.ID] = {
      ["setDishwasherMode"] = handle_dishwasher_mode,
    },
    [capabilities.dishwasherOperatingState.ID] = {
      ["setMachineState"] = handle_dishwasher_operating_state,
    },

    [ThermostatMode.ID] = {
      ["setThermostatMode"] = handle_thermostat_mode,
    },

    [FanOscillationMode.ID] = {
      ["setFanOscillationMode"] = handle_fan_oscillation_mode,
    },

    [FanSpeed.ID] = {
      ["setFanSpeed"] = handle_fan_speed,
    },

    [DishwasherBaskets.ID] = {
      ["setBaskets"] = handle_dishwasher_baskets,
    },
    [CoffeeBrew.ID] = {
      ["setBrew"] = handle_coffee_brew
    },
    [CoffeeWater.ID] = {
      ["setWaterLevel"] = handle_water_level
    },
    [CoffeeStength.ID] = {
      ["setStrength"] = handle_coffee_strength
    },
    [capabilities.robotCleanerMovement.ID] = {
      ["setRobotCleanerMovement"] = handle_coffee_operating_state
    },
  }
})

log.info ('MQTT Device Handler V1.1 Started!!!')

thisDriver:run()
