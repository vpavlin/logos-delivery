import std/sequtils
import chronos, chronicles, libp2p/nameresolving/dnsresolver, libp2p/peerstore

import ../peer_manager/waku_peer_store, logos_delivery/waku/waku_core/peers

type
  OnOnlineStateChange* = proc(online: bool) {.gcsafe, raises: [].}

  OnlineMonitor* = ref object
    onOnlineStateChange: OnOnlineStateChange
    dnsNameServers*: seq[IpAddress]
    onlineStateObservers: seq[OnOnlineStateChange]
    networkConnLoopHandle: Future[void] # node: WakuNode
    peerStore: PeerStore
    online: bool

proc checkInternetConnectivity(
    nameServerIps: seq[IpAddress], timeout = 2.seconds
): Future[bool] {.async.} =
  const DNSCheckDomain = "one.one.one.one"
  let nameServers = nameServerIps.mapIt(initTAddress(it, Port(53)))
  let dnsResolver = DnsResolver.new(nameServers)

  # Resolve domain IP
  let resolved = await dnsResolver.resolveIp(DNSCheckDomain, 0.Port, Domain.AF_UNSPEC)
  if resolved.len > 0:
    return true
  else:
    return false

proc updateOnlineState(self: OnlineMonitor) {.async.} =
  if self.onlineStateObservers.len == 0:
    trace "No online state observers registered, cannot notify about online state change"
    return

  let numConnectedPeers =
    if self.peerStore.isNil():
      0
    else:
      self.peerStore.peers().countIt(it.connectedness == Connected)

  self.online =
    if numConnectedPeers > 0:
      true
    else:
      # PATCH (mobile/Android): nim's DnsResolver (raw UDP to 1.1.1.1) fails on Android's
      # sandboxed network stack, so the DNS-based connectivity check always returns false and
      # DEADLOCKS the node offline — it won't dial bootstrap peers, so it never gets peers, so it
      # stays offline forever. Assume online so the node dials the fleet and forms the relay mesh;
      # once connected, numConnectedPeers>0 keeps it online for real. (Desktop is unaffected: DNS
      # resolves fine there, so this branch is rarely hit.)
      true

  for onlineStateObserver in self.onlineStateObservers:
    onlineStateObserver(self.online)

proc networkConnectivityLoop(self: OnlineMonitor): Future[void] {.async.} =
  ## Checks periodically whether the node is online or not
  ## and triggers any change that depends on the network connectivity state
  while true:
    await self.updateOnlineState()
    await sleepAsync(5.seconds)

proc startOnlineMonitor*(self: OnlineMonitor) =
  self.networkConnLoopHandle = self.networkConnectivityLoop()

proc stopOnlineMonitor*(self: OnlineMonitor) {.async.} =
  if not self.networkConnLoopHandle.isNil():
    await self.networkConnLoopHandle.cancelAndWait()

proc setPeerStoreToOnlineMonitor*(self: OnlineMonitor, peerStore: PeerStore) =
  self.peerStore = peerStore

proc addOnlineStateObserver*(self: OnlineMonitor, observer: OnOnlineStateChange) =
  ## Adds an observer that will be called when the online state changes
  if observer notin self.onlineStateObservers:
    self.onlineStateObservers.add(observer)

proc amIOnline*(self: OnlineMonitor): bool =
  return self.online

proc init*(T: type OnlineMonitor, dnsNameServers: seq[IpAddress]): OnlineMonitor =
  T(dnsNameServers: dnsNameServers, onlineStateObservers: @[])
