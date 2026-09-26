[CmdletBinding()]
param(
    [string]$Source = 'D:/eval-corpus/sales/real/breeze-2026-06.pdf',
    [string]$Destination = 'D:/nila-demo/breeze-2026-06'
)
$ErrorActionPreference = 'Stop'
$expectedHash = 'CFB7E59EE7085F083D081C5C4E77249A45214CC503C577693907701A99D47608'
if ((Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash -ne $expectedHash) {
    throw 'This is not the rehearsed June 2026 packet. Source hash differs.'
}
New-Item -ItemType Directory -Force -Path $Destination | Out-Null
$demoPdf = Join-Path $Destination 'Breeze Tech - June 2026 - Sales.pdf'
if (Test-Path -LiteralPath $demoPdf) {
    if ((Get-FileHash -LiteralPath $demoPdf -Algorithm SHA256).Hash -ne $expectedHash) {
        throw 'An existing demo file has different bytes. It has not been overwritten.'
    }
} else {
    Copy-Item -LiteralPath $Source -Destination $demoPdf
}
if ((Get-FileHash -LiteralPath $demoPdf -Algorithm SHA256).Hash -ne $expectedHash) {
    throw 'The copied demo packet failed verification.'
}
Write-Output "Verified: $demoPdf"
Write-Output 'June 2026 | 8 pages | 8 invoices | 33AEWPH4158J1Z3'
Write-Output 'Create and select a client with the packet GSTIN in your demo firm before uploading.'
