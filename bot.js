import { Client, GatewayIntentBits, REST, Routes } from 'discord.js';
import { mkdirSync } from 'fs';
import { execSync } from 'child_process';
import { SESSIONS_DIR } from './src/constants.js';

// Kill any existing bot.js instances before starting (prevents duplicate bots)
try {
  execSync(
    `powershell -Command "Get-CimInstance Win32_Process -Filter \\"name='node.exe'\\" | Where-Object { $_.CommandLine -like '*bot.js*' -and $_.ProcessId -ne ${process.pid} } | ForEach-Object { Write-Host \\"[startup] Killed existing bot PID $($_.ProcessId)\\"; Stop-Process -Id $_.ProcessId -Force }"`,
    { stdio: 'inherit' }
  );
} catch {}
import { BOT_TOKEN } from './src/config.js';
import { activeSessions, setClient } from './src/state.js';
import { commands } from './src/commands.js';
import { loadAllSessions, saveSession, isSessionBusy } from './src/session.js';
import { handleInteractionCreate } from './src/handlers/interactions.js';
import { handleMessageCreate } from './src/handlers/message.js';
import { startAllTimers } from './src/timers.js';

const client = new Client({
  intents: [
    GatewayIntentBits.Guilds,
    GatewayIntentBits.GuildMessages,
    GatewayIntentBits.MessageContent,
  ],
});

setClient(client);

client.once('ready', async () => {
  console.log(`✅ Bot logged in: ${client.user.tag}`);
  mkdirSync(SESSIONS_DIR, { recursive: true });

  // Register slash commands for every guild the bot is currently in
  const rest = new REST({ version: '10' }).setToken(BOT_TOKEN);
  for (const [guildId, guild] of client.guilds.cache) {
    try {
      await rest.put(Routes.applicationGuildCommands(client.user.id, guildId), {
        body: commands.map(c => c.toJSON()),
      });
      console.log(`✅ Registered ${commands.length} slash commands in "${guild.name}"`);
    } catch (e) {
      console.error(`Failed to register commands in "${guild.name}":`, e);
    }
  }
  // Clear any stale global commands
  try { await rest.put(Routes.applicationCommands(client.user.id), { body: [] }); } catch {}

  // Restore persisted sessions from disk on bot restart
  try {
    const savedSessions = loadAllSessions();
    let restored = 0;
    for (const data of savedSessions) {
      if (data.endedAt) continue;
      try {
        const channel = await client.channels.fetch(data.channelId);
        let threadRef = null;
        let starterMessageRef = null;
        if (data.threadId) {
          threadRef = await client.channels.fetch(data.threadId).catch(() => null);
        }
        if (data.starterMessageId && channel) {
          starterMessageRef = await channel.messages.fetch(data.starterMessageId).catch(() => null);
        }
        const session = {
          ...data,
          proc: null,
          threadRef,
          starterMessageRef,
          lastThreadButtonMsg: null,
          pendingMessages: [],
        };
        activeSessions.set(data.channelId, session);
        restored++;
        console.log(`[restore] Restored session: ${data.projectName} (${data.turnCount} turns)`);
      } catch (e) {
        console.warn(`[restore] Failed to restore session: ${data.projectName}`, e.message);
        data.endedAt = Date.now();
        saveSession(data);
      }
    }
    if (restored > 0) console.log(`[restore] Restored ${restored} session(s)`);
  } catch (e) {
    console.warn('[restore] Session restore error:', e.message);
  }

  startAllTimers();
});

client.on('interactionCreate', handleInteractionCreate);
client.on('messageCreate', handleMessageCreate);

function shutdown() {
  console.log('Shutting down...');
  for (const [, session] of activeSessions) {
    try { saveSession(session); } catch {}
    if (isSessionBusy(session)) session.proc.kill('SIGKILL');
  }
  client.destroy();
  process.exit(0);
}
process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);

client.login(BOT_TOKEN).catch(err => {
  console.error('Bot login failed:', err.message);
  process.exit(1);
});
