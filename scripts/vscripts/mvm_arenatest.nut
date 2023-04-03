
// bind o "script_execute mvm_arenatest; tf_bot_kill all"

const ARENA_RADIUS              = 500.0;

local ARENA_DEBUG_LOCOMOTION    = 1 << 0;
local ARENA_DEBUG_REVIVE        = 1 << 1;
local ARENA_DEBUG               = ARENA_DEBUG_LOCOMOTION | ARENA_DEBUG_REVIVE;

//
// Currency packs
//

const CURRENCY_PACK_LIFETIME        = 7.0;
const CURRENCY_PACK_FADETIME        = 4.5;
const CURRENCY_PACK_MAX_FADE_SPEED  = 2.0;

function Currency_OnSpawn() {
    if ( !self.IsValid() ) { return 0.0; }

    self.ValidateScriptScope();
    self.GetScriptScope().m_flFadeStartTime <- Time() + CURRENCY_PACK_FADETIME;
    self.GetScriptScope().m_flDespawnTime   <- Time() + CURRENCY_PACK_LIFETIME;
    AddThinkToEnt(self, "Currency_OnThink");
}

function Currency_OnThink() {
    if ( !self.IsValid() ) { return 0.0; }

    if ( Time() >= self.GetScriptScope().m_flFadeStartTime ) {
        local speed  = ( Time() - self.GetScriptScope().m_flFadeStartTime ) / ( self.GetScriptScope().m_flDespawnTime - self.GetScriptScope().m_flFadeStartTime );
        speed *= CURRENCY_PACK_MAX_FADE_SPEED;
        speed += 1.0;
        local factor = ( sin( 1.5707 + ( Time() - self.GetScriptScope().m_flFadeStartTime ) * 10.0 * speed ) + 1.0 ) / 2.0;
        local flash  = ( 0xFF.tofloat() * factor ).tointeger() & 0xFF;
        NetProps.SetPropInt( self, "m_clrRender", 0xFF | ( flash << 8 ) | ( flash << 16 ) | ( flash << 24 ) );
        if ( Time() >= self.GetScriptScope().m_flDespawnTime ) {
            self.Kill();
        }
    }

    return 0.0;
}

//
// Reanimators
//

function Reanimator_OnSpawn() {
    if ( !self.IsValid() ) { return 0.0; }

    self.ValidateScriptScope();
    AddThinkToEnt(self, "Reanimator_OnThink");
}

function Reanimator_OnThink() {
    if ( !self.IsValid() ) { return 0.0; }

    // Revive via nearby teammates
    local player = null;
    while ( player = Entities.FindByClassnameWithin( player, "player", self.GetOrigin(), 500.0 ) ) {
        // Must be an alive teammate
        if ( NetProps.GetPropInt( player, "m_lifeState" ) == 0 ) {
            if ( ARENA_DEBUG & ARENA_DEBUG_REVIVE ) {
                DebugDrawLine( self.GetOrigin(), player.GetOrigin(), 0, 255, 0, false, 0.1 );
            }
            self.SetHealth( self.GetHealth() + 1 );
            printl( "Reanimator: Set HP to " + self.GetHealth() )
        }
    }

    // Revive owner
    if ( self.GetHealth() >= self.GetMaxHealth() ) {
        local owner = NetProps.GetPropEntity( self, "m_hOwner" );
        if ( owner && owner.IsValid() ) {
            local respawn_pos = self.GetOrigin();
            respawn_pos.z += 200.0;
            owner.ForceRespawn();
            owner.SetAbsOrigin( respawn_pos );
        }
    }

    return 0.0;
}

//
// Humans
//

function Human_OnSpawn() {
    if ( !self.IsValid() ) { return 0.0; }

    // Engineer only
    if ( self.GetPlayerClass() != Constants.ETFClass.TF_CLASS_ENGINEER ) {
        ClientPrint( self, Constants.EHudNotify.HUD_PRINTCENTER, "Only engineer is allowed" )
        ClientPrint( self, Constants.EHudNotify.HUD_PRINTTALK, "Only engineer is allowed" )
        return;
    }

    // self.AddCustomAttribute("max health additive penalty", -124, -1);
    // self.SetHealth(self.GetMaxHealth());
    
    // Hijack weapons
    local primary = NetProps.GetPropEntityArray( self, "m_hMyWeapons", 0 );
    // primary.AddAttribute("fire rate bonus", 0.25, -1);
    primary.AddAttribute( "fire rate bonus", 0.6, -1 );
    primary.RemoveAttribute( "mod use metal ammo type" )
    primary.RemoveAttribute( "mod ammo per shot" )
    // primary.AddAttribute("sniper fires tracer", 1, -1);
    AddThinkToEnt( primary, "Human_WeaponThink" );

    local secondary = NetProps.GetPropEntityArray( self, "m_hMyWeapons", 1 );
    secondary.AddAttribute( "critboost on kill", 5, -1 );
    AddThinkToEnt( secondary, "Human_WeaponThink" );

    local melee = NetProps.GetPropEntityArray( self, "m_hMyWeapons", 2 );
    melee.AddAttribute( "attach particle effect", 2, -1 );

    AddThinkToEnt( self, "Human_Think" );
}

function Human_Think() {
    if ( !self.IsValid() ) { return 0.0; }

    // Collect money if not attacking
    // TODO move this to currency pack code
    local buttons = NetProps.GetPropInt( self, "m_nButtons" );
    if ( !( buttons & Constants.FButtons.IN_ATTACK ) ) {
        local pack = null;
        while ( pack = Entities.FindByClassname( pack, "item_currencypack_custom" ) ) {
            local dir = GetListenServerHost().GetOrigin() + Vector( 0, 0, 20 ) - pack.GetOrigin();
            if ( dir.Length() <= 100.0 ) {
                pack.SetAbsOrigin( GetListenServerHost().GetOrigin() );
            }
            dir.Norm();
            pack.SetAbsVelocity( dir * 50000.0 * FrameTime() );
        }
    }

    // Use high FOV
    NetProps.SetPropInt( self, "m_iFOV", 105 );

    return 0.0;
}

function Human_WeaponThink() {
    if ( !self.IsValid() ) { return 0.0; }

    self.SetClip1( self.GetMaxClip1() )
    self.SetClip2( self.GetMaxClip2() )
    NetProps.SetPropFloat( self, "m_flEnergy", 100 );

    return 0.0;
}

//
// Pyro AI
//

function Pyro_OnSpawn() {
    if ( !self.IsValid() ) { return 0.0; }

    AddThinkToEnt( self, "Pyro_OnThink" );
}

function Pyro_OnThink() {
    if ( !self.IsValid() ) { return 0.0; }

    // Only tick if alive
    if ( NetProps.GetPropInt(self, "m_lifeState" ) != 0) {
        return 0.0;
    }

    // Predict the players path and try to intercept
    local loco = self.GetLocomotionInterface();
    if ( loco ) {
        local myspeed = self.GetAbsVelocity().Length();
        local tgt = GetListenServerHost().GetOrigin();
        tgt += GetListenServerHost().GetAbsVelocity() * ( ( tgt - self.GetOrigin() ).Length() / myspeed * 0.5 );
        loco.DriveTo( tgt );
        if ( ARENA_DEBUG & ARENA_DEBUG_LOCOMOTION ) {
            DebugDrawLine( self.GetOrigin(), tgt, 0, 255, 0, false, 0.1 );
        }
    }

    return 0.0;
}

//
// Roamer AI
//

function Roamer_OnSpawn() {
    if ( !self.IsValid() ) { return 0.0; }

    self.ValidateScriptScope();
    self.GetScriptScope().m_vecGuardPos <- Vector();
    self.GetScriptScope().m_flNextGuardCalc <- 0.0;
    AddThinkToEnt( self, "Roamer_OnThink" );
}

function Roamer_OnThink() {
    if ( !self.IsValid() ) { return 0.0; }

    // Only tick if alive
    if ( NetProps.GetPropInt( self, "m_lifeState" ) != 0 ) {
        return 0.0;
    }

    // Recalculate position
    if ( self.GetScriptScope().m_flNextGuardCalc <= Time() ) {
        self.GetScriptScope().m_vecGuardPos = Vector( RandomFloat( -ARENA_RADIUS, ARENA_RADIUS ), RandomFloat( -ARENA_RADIUS, ARENA_RADIUS ), self.GetOrigin().z )
        self.GetScriptScope().m_flNextGuardCalc = Time() + RandomFloat( 2, 5 );
    }

    // Locomote
    local loco = self.GetLocomotionInterface();
    if ( loco ) {
        loco.DriveTo( self.GetScriptScope().m_vecGuardPos );
        if ( ARENA_DEBUG & ARENA_DEBUG_LOCOMOTION ) {
            DebugDrawLine( self.GetOrigin(), self.GetScriptScope().m_vecGuardPos, 0, 255, 0, false, 0.1 );
        }
    }

    return 0.0;
}

//
// Flocking AI
//

const BOID_VISION   = 500.0;    // Boid neighbor threshold
const BOID_AVOID    = 30;       // How much space a boid wants between itself and its closest neighbor

function Boid_OnSpawn() {
    if ( !self.IsValid() ) { return 0.0; }

    AddThinkToEnt( self, "Boid_OnThink" );
}

function Boid_OnThink() {
    if ( !self.IsValid() ) { return 0.0; }

    // Only tick if alive
    if ( NetProps.GetPropInt( self, "m_lifeState" ) != 0 ) {
        return 0.0;
    }

    // Collect neighbors
    local neighbors = []
    local close_neighbors = []
    for ( local i = 1; i <= Constants.Server.MAX_PLAYERS; ++i ) {
        local player = PlayerInstanceFromIndex( i );
        // Neighbors need to be valid
        if ( !player || !player.IsValid() ) {
            continue;
        }
        // Only alive boids
        if ( NetProps.GetPropInt( player, "m_lifeState" ) != 0 || NetProps.GetPropString( player, "m_iszScriptThinkFunction" ) != "Boid_OnThink" ) {
            continue;
        }
        local dist = ( self.GetOrigin() - player.GetOrigin() ).Length();
        if ( dist <= BOID_VISION ) {
            neighbors.append( player )
            if ( dist <= BOID_AVOID ) {
                close_neighbors.append( player )
            }
        }
    }

    // Calculate average positions / velocities of neighbors
    local avg_pos = self.GetOrigin();
    local avg_vel = self.GetAbsVelocity();
    if ( neighbors.len() > 0 ) {
        avg_pos = Vector( 0, 0, 0 );
        avg_vel = Vector( 0, 0, 0 );
        for ( local i = 0; i < neighbors.len(); ++i ) {
            avg_pos += neighbors[i].GetOrigin();
            avg_vel += neighbors[i].GetAbsVelocity();
        }
        avg_pos *= ( 1.0 / neighbors.len() );
        avg_vel *= ( 1.0 / neighbors.len() );
    }

    // Boid separation
    local vec_s = Vector( 0, 0, 0 );
    for ( local i = 0; i < close_neighbors.len(); ++i ) {
        vec_s += ( close_neighbors[i].GetOrigin() - self.GetOrigin() )
    }

    // Boid alignment
    local vec_a = avg_vel - self.GetAbsVelocity();

    // Boid cohesion
    local vec_c = avg_pos - self.GetOrigin();

    // Track towards target
    local vec_t = GetListenServerHost().GetOrigin() - self.GetOrigin();

    // Apply motion
    local vel = self.GetAbsVelocity() + vec_a + vec_c * 2.0 + vec_a + vec_t * 0.66;
    vel.z = 0.0;
    local loco = self.GetLocomotionInterface();
    if ( loco ) {
        local target = self.GetOrigin() + vel * FrameTime();
        loco.DriveTo( target );

        if ( ARENA_DEBUG & ARENA_DEBUG_LOCOMOTION ) {
            DebugDrawBox( avg_pos, Vector( -10, -10, -10 ), Vector( 10, 10, 10 ), 255, 0, 0, 255, 0.1);
            DebugDrawLine( avg_pos, avg_pos + avg_vel, 255, 0, 0, false, 0.1);
        }
    }

    return 0.0;
}

//
// Game rules
//

function GetGamerules() {
    local gamerules = Entities.FindByName( null, "arena_mvm_driver" );
    if ( gamerules != null && !gamerules.IsValid() ) {
        gamerules.Kill();
        gamerules = null;
    }
    if ( !gamerules ) {
        gamerules = SpawnEntityFromTable( "logic_script", { targetname = "arena_mvm_driver" } );
    }
    if ( !gamerules.GetScriptScope() ) {
       EntFireByHandle( gamerules, "RunScriptCode", "Game_OnSpawn()", 0.0, null, null ); 
    }
    return gamerules;
}

function Game_OnSpawn() {
    if ( !self.IsValid() ) { return 0.0; }

    self.ValidateScriptScope();
    AddThinkToEnt( self, "Game_OnThink" );
}

function Game_OnThink() {
    if ( !self.IsValid() ) { return 0.0; }

    // Watch for new currency pack spawns
    local pack = null;
    while ( pack = Entities.FindByClassname( pack, "item_currencypack_custom" ) ) {
        if ( pack.GetScriptScope() == null ) {
            EntFireByHandle( pack, "RunScriptCode", "Currency_OnSpawn()", 0.0, null, null );
        }
    }

    // Watch for new reanimator spawns
    local reanim = null;
    while ( reanim = Entities.FindByClassname( reanim, "entity_revive_marker" ) ) {
        if ( reanim.GetScriptScope() == null ) {
            EntFireByHandle( reanim, "RunScriptCode", "Reanimator_OnSpawn()", 0.0, null, null );
        }
    }

    return 0.0;
}

//
// Game event drivers
//

// Game reset also kills this entity
function OnGameEvent_mvm_reset_stats( params ) {
    GetGamerules();
}

function OnGameEvent_player_spawn( params ) {
    local player = GetPlayerFromUserID( params.userid );
    if ( player && player.IsValid() ) {
        switch ( player.GetTeam() ) {
            // Robots
            case Constants.ETFTeam.TF_TEAM_PVE_INVADERS: {
                switch ( player.GetPlayerClass() ) {
                    case Constants.ETFClass.TF_CLASS_SCOUT: {
                        EntFireByHandle( player, "RunScriptCode", "Boid_OnSpawn()", 0.0, null, null );
                        break;
                    };
                    case Constants.ETFClass.TF_CLASS_PYRO: {
                        EntFireByHandle( player, "RunScriptCode", "Pyro_OnSpawn()", 0.0, null, null );
                        break;
                    };
                    case Constants.ETFClass.TF_CLASS_HEAVYWEAPONS: {
                        EntFireByHandle( player, "RunScriptCode", "Roamer_OnSpawn()", 0.0, null, null );
                        break;
                    };
                }
                break;
            };
            // Humans
            case Constants.ETFTeam.TF_TEAM_PVE_DEFENDERS: {
                EntFireByHandle( player, "RunScriptCode", "Human_OnSpawn()", 0.0, null, null );
                break;
            };
        }
    }
}

function OnGameEvent_mvm_pickup_currency( params ) {
    local player = PlayerInstanceFromIndex( params.player );
    if ( player && player.IsValid() ) {
        if ( player.GetHealth() < player.GetMaxHealth() ) {
            player.SetHealth( player.GetHealth() + 5 );
        }
    }
}

__CollectGameEventCallbacks( this );
GetGamerules();
