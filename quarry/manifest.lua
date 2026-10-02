-- File manifest for bootstrap.lua. Keep in sync with lib/, worker/, master/.
return {
  common = {
    "lib/comms.lua",
    "lib/directions.lua",
    "lib/errors.lua",
    "lib/fuel.lua",
    "lib/gpsnav.lua",
    "lib/inventory.lua",
    "lib/logging.lua",
    "lib/mining.lua",
    "lib/navigation.lua",
    "lib/partition.lua",
    "lib/persistence.lua",
    "lib/protocol.lua",
    "lib/state_machine.lua",
    "lib/traversal.lua",
    "lib/validation.lua",
  },
  worker = {
    "worker/startup.lua",
    "worker/worker.lua",
  },
  master = {
    "master/startup.lua",
    "master/master.lua",
  },
}
