// Shared in-process state — kept in a leaf module to prevent circular dependencies

// Maps channelId → session object
export const activeSessions = new Map();

let _client = null;

export function getClient() {
  return _client;
}

export function setClient(c) {
  _client = c;
}
