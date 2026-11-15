# Sends a Claude agent state to MiniChroma on 127.0.0.1:47800.
# States: thinking, editing, done, needs_input, idle. Does nothing if MiniChroma is not running.
param([string]$Status = "idle")
$message = '{"type":"agent","status":"' + $Status + '"}'
$bytes = [System.Text.Encoding]::UTF8.GetBytes($message)
$udp = New-Object System.Net.Sockets.UdpClient
try { [void]$udp.Send($bytes, $bytes.Length, "127.0.0.1", 47800) } catch {} finally { $udp.Close() }
exit 0
