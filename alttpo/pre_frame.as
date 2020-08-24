
// this function intercepts execution immediately before JSL MainRouting in the reset vector:
// this function is not called for every frame but is for most frames.
// when it is called, this function is always called before pre_frame.
// in SMZ3 this function is only called during ALTTP game.
void on_main_alttp(uint32 pc) {
  //message("main_alttp");

  // restore our dynamic code buffer to JSL MainRouting; RTL:
  pb.restore();

  if (!enableRenderToExtra) {
    // reset ownership of OAM sprites:
    localFrameState.reset_owners();
  }

  local.fetch();

  if (settings.SyncTunic) {
    local.update_palette();
  }

  if (!enableRenderToExtra) {
    // backup VRAM for OAM tiles which are in-use by game:
    localFrameState.backup();
  }

  // fetch local VRAM data for sprites:
  local.capture_sprites_vram();

  if (settings.started && !(sock is null)) {
    // send updated state for our Link to server:
    local.send();

    // receive network updates from remote players:
    receive();
  }

  if (!settings.RaceMode) {
    ALTTPSRAMArray @sram = @ALTTPSRAMArray(@local.sram);

    local.update_tilemap();

    local.update_wram();

    local.update_ancillae();

    if ((local.frame & 15) == 0) {
      local.update_items(sram);
    }

    if ((local.frame & 31) == 0) {
      local.update_rooms(sram);
    }
    if ((local.frame & 31) == 16) {
      local.update_overworld(sram);
    }

    // write back any changes to SRAM:
    sram.commit();

    if (enableObjectSync) {
      local.update_objects();
    }

    // synchronize torches:
    update_torches();
  }

  if (pb.offset > 0) {
    // end the patch buffer:
    pb.jsl(rom.fn_main_routing);  // JSL MainRouting
    pb.rtl();                     // RTL
  }
}

uint8 sm_state = 0;

bool sm_is_safe_state() {
  // on SM reset: 00, 01, 04, 02, 1f, 07, 08 (in game)
  // on SM transition: 0b

  if (sm_state < 0x07) return false;
  if (sm_state >= 0x1f) return false;

  return true;
}

// Super Metroid main loop intercept:
void on_main_sm(uint32 pc) {
  //message("main_sm");

  rom.check_game();

  sm_state = bus::read_u8(0x7E0998);

  local.module = 0x00;
  local.sub_module = 0x00;
  local.sub_sub_module = 0x00;
  local.sprites_need_vram = false;
  local.numsprites = 0;
  local.sprites.resize(0);
  local.actual_location = 0;

  if (sm_is_safe_state()) {
    // read ALTTP temporary item buffer from SM SRAM:
    bus::read_block_u8(0xA17B00, 0x300, 0x100, local.sram);
  }

  if (settings.started && (sock !is null)) {
    // send updated state for our Link to server:
    local.send();

    // receive network updates from remote players:
    receive();
  }

  if (!settings.RaceMode) {
    // all we can do is update items:
    if ((local.frame & 15) == 0) {
      if (sm_is_safe_state()) {
        // use SMSRAMArray so that commit() updates SM SRAM:
        SMSRAMArray@ sram = @SMSRAMArray(@local.sram);

        local.update_items(sram);

        sram.commit();
      }
    }
  }
}

// pre_frame always happens
void pre_frame() {
  //message("pre_frame");

  // capture current timestamp:
  // TODO(jsd): replace this with current server time
  timestamp_now = uint32(chrono::realtime::millisecond);

  if (enableRenderToExtra) {
    ppu::extra.count = 0;
    ppu::extra.text_outline = true;
    if (!font_set) {
      @ppu::extra.font = settings.Font;
      font_set = true;
    }
  }

  if (settings.DiscordEnable) {
    discord::pre_frame();
  }

  if (settings.Bridge) {
    bridge.main();
  }

  if (rom is null) {
    return;
  }

  rom.check_game();

  local.ttl = 255;

  // render remote players:
  int ei = 0;
  uint len = players.length();
  playerCount = 0;
  for (uint i = 0; i < len; i++) {
    auto @remote = players[i];
    if (remote is null) continue;
    playerCount++;
    if (remote is local) continue;
    if (remote.ttl <= 0) {
      remote.ttl = 0;
      playerCount--;
      continue;
    }
    remote.ttl_count();

    // exit early if game is not ALTTP (for SMZ3):
    if (!rom.is_alttp()) {
      continue;
    }

    // don't render players or labels in pre-game modules:
    if (local.is_it_a_bad_time()) continue;

    // only draw remote player if location (room, dungeon, light/dark world) is identical to local player's:
    if (local.can_see(remote.location)) {
      // don't render player if remote player is in pre-game modules:
      if (remote.is_it_a_bad_time()) continue;

      // calculate screen scroll offset between both players to adjust OAM sprite x,y coords:
      int rx = int(remote.xoffs - local.xoffs);
      int ry = int(remote.yoffs - local.yoffs);

      // draw remote player relative to current BG offsets:
      if (enableRenderToExtra) {
        ei = remote.renderToExtra(rx, ry, ei);

        if (settings.ShowLabels) {
          ei = remote.renderLabel(rx, ry, ei);
        }
      } else {
        remote.renderToPPU(rx, ry);
      }
    }
  }

  if (enableRenderToExtra) {
    if (settings.ShowMyLabel && rom.is_alttp()) {
      // don't render on in-game map:
      if ((local.module >= 0x06) && !( local.module == 0x0e && local.sub_module == 0x07 )) {
        ei = local.renderLabel(0, 0, ei);
      }
    }

    if (rom.is_alttp()) {
      // don't render notifications during spotlight open/close:
      if (local.module >= 0x07 && local.module <= 0x18) {
        if (local.module != 0x08 && local.module != 0x0a
         && local.module != 0x0d && local.module != 0x0e
         && local.module != 0x0f && local.module != 0x10) {
          // TODO: checkbox to enable/disable
          ei = local.renderNotifications(ei);
        }
      }
    } else {
      // SM:
      sm_state = bus::read_u8(0x7E0998);
      if (sm_is_safe_state()) {
        ei = local.renderNotifications(ei);
      }
    }

    if (ei > 0) {
      ppu::extra.count = ei;
    }
  }
}