# make-icons.ps1
#
# Outputs: the app's icon files, in MusicAssistant\Assets.
#   app.ico             the colored icon, for the window, the taskbar and the tray
#   app-mono-light.ico  white silhouette, for the tray on a dark taskbar
#   app-mono-dark.ico   black silhouette, for the tray on a light taskbar
#   app-512.png         the colored icon at 512px, the source for make-msix-assets.ps1
#
# Each .ico holds 16, 20, 24, 32, 40, 48, 64, 128 and 256px frames. The 20, 24 and 40px
# ones are what the notification area asks for at 125%, 150% and 250% scaling; without
# them the shell stretches the nearest frame and the tray icon looks blurry.
#
# Used for: the app icon and the "monochrome tray icon" setting.
#
# Source: lazules.svg in the repo root. Every frame is drawn from it at its own size.
# For the monochrome pair, all of its shapes go into one figure with the even-odd fill
# rule, so the note knocks out of the circle and the icon reads as a single silhouette
# in one flat color.
#
# Depends on: System.Drawing (ships with Windows PowerShell / .NET). The parser below
# handles what the SVG uses: nested <g transform="matrix(...)"> groups, <circle>, <path>
# with absolute M, L, C and Z commands, and two-stop userSpaceOnUse linear gradients.
#   https://learn.microsoft.com/windows/win32/menurc/icon-resource
#
# Usage: .\tools\make-icons.ps1

Add-Type -AssemblyName System.Drawing

$svgPath   = Join-Path $PSScriptRoot "..\lazules.svg"
$dest      = Join-Path $PSScriptRoot "..\MusicAssistant\Assets"
$sizes     = 16, 20, 24, 32, 40, 48, 64, 128, 256

# The SVG's user space; every frame scales down from it
$viewBox = 256

# Turn one SVG path's d attribute into a GraphicsPath
function ConvertTo-GraphicsPath([string] $d) {
    $path  = New-Object System.Drawing.Drawing2D.GraphicsPath
    $point = New-Object System.Drawing.PointF 0, 0
    $start = $point

    foreach ($segment in [regex]::Matches($d, '([MLCZ])([^MLCZ]*)')) {
        $command = $segment.Groups[1].Value
        $numbers = @([regex]::Matches($segment.Groups[2].Value, '-?[0-9]*\.?[0-9]+') | ForEach-Object { [float] $_.Value })

        switch ($command) {
            # Move, then any further pairs are implicit lines
            'M' {
                $path.StartFigure()
                $point = New-Object System.Drawing.PointF $numbers[0], $numbers[1]
                $start = $point
                for ($i = 2; $i -lt $numbers.Count; $i += 2) {
                    $next = New-Object System.Drawing.PointF $numbers[$i], $numbers[$i + 1]
                    $path.AddLine($point, $next)
                    $point = $next
                }
            }
            'L' {
                for ($i = 0; $i -lt $numbers.Count; $i += 2) {
                    $next = New-Object System.Drawing.PointF $numbers[$i], $numbers[$i + 1]
                    $path.AddLine($point, $next)
                    $point = $next
                }
            }
            'C' {
                for ($i = 0; $i -lt $numbers.Count; $i += 6) {
                    $c1   = New-Object System.Drawing.PointF $numbers[$i],     $numbers[$i + 1]
                    $c2   = New-Object System.Drawing.PointF $numbers[$i + 2], $numbers[$i + 3]
                    $next = New-Object System.Drawing.PointF $numbers[$i + 4], $numbers[$i + 5]
                    $path.AddBezier($point, $c1, $c2, $next)
                    $point = $next
                }
            }
            'Z' {
                $path.CloseFigure()
                $point = $start
            }
        }
    }
    return $path
}

# A System.Drawing matrix from an SVG matrix(a,b,c,d,e,f) argument list
function ConvertTo-Matrix([string] $values) {
    $m = @($values -split '[,\s]+' | ForEach-Object { [float] $_ })
    return New-Object System.Drawing.Drawing2D.Matrix $m[0], $m[1], $m[2], $m[3], $m[4], $m[5]
}

# A color from an SVG stop-color: rgb(r,g,b) or a named color
function ConvertTo-Color([string] $value) {
    if ($value -match 'rgb\((\d+),(\d+),(\d+)\)') {
        return [System.Drawing.Color]::FromArgb([int] $Matches[1], [int] $Matches[2], [int] $Matches[3])
    }
    return [System.Drawing.Color]::FromName($value)
}

# Every filled shape in the SVG, in viewBox space: its outline and its gradient's two ends and colors.
# Walks the tags in order, keeping a stack of group matrices so nested transforms compose.
function Get-SvgShapes([string] $svg) {
    # Gradients by id: their two end points (gradientTransform applied) and two stop colors
    $gradients = @{}
    foreach ($gradient in [regex]::Matches($svg, '(?s)<linearGradient id="([^"]+)" x1="([^"]+)" y1="([^"]+)" x2="([^"]+)" y2="([^"]+)"[^>]*gradientTransform="matrix\(([^)]+)\)">(.*?)</linearGradient>')) {
        $matrix = ConvertTo-Matrix $gradient.Groups[6].Value
        $ends   = [System.Drawing.PointF[]] @(
            (New-Object System.Drawing.PointF ([float] $gradient.Groups[2].Value), ([float] $gradient.Groups[3].Value)),
            (New-Object System.Drawing.PointF ([float] $gradient.Groups[4].Value), ([float] $gradient.Groups[5].Value))
        )
        $matrix.TransformPoints($ends)
        $matrix.Dispose()

        $colors = @([regex]::Matches($gradient.Groups[7].Value, 'stop-color:([^;"]+)') | ForEach-Object { ConvertTo-Color $_.Groups[1].Value })
        $gradients[$gradient.Groups[1].Value] = @{ Ends = $ends; Colors = $colors }
    }

    $shapes = New-Object System.Collections.ArrayList
    $stack  = New-Object System.Collections.Stack
    $stack.Push((New-Object System.Drawing.Drawing2D.Matrix))

    foreach ($tag in [regex]::Matches($svg, '<g transform="matrix\(([^)]+)\)">|</g>|<(circle|path)\s([^>]*)/>')) {
        if ($tag.Value -eq '</g>') {
            $stack.Pop().Dispose()
            continue
        }

        # Group: its matrix applies first, then every enclosing group's
        if ($tag.Groups[1].Success) {
            $matrix = ConvertTo-Matrix $tag.Groups[1].Value
            $matrix.Multiply($stack.Peek(), [System.Drawing.Drawing2D.MatrixOrder]::Append)
            $stack.Push($matrix)
            continue
        }

        $attributes = $tag.Groups[3].Value
        if ($tag.Groups[2].Value -eq 'circle') {
            $cx = [float] ([regex]::Match($attributes, 'cx="([^"]+)"').Groups[1].Value)
            $cy = [float] ([regex]::Match($attributes, 'cy="([^"]+)"').Groups[1].Value)
            $r  = [float] ([regex]::Match($attributes, '\sr="([^"]+)"').Groups[1].Value)
            $path = New-Object System.Drawing.Drawing2D.GraphicsPath
            $path.AddEllipse($cx - $r, $cy - $r, 2 * $r, 2 * $r)
        }
        else {
            $path = ConvertTo-GraphicsPath ([regex]::Match($attributes, '\bd="([^"]+)"').Groups[1].Value)
        }

        # userSpaceOnUse gradients live in the shape's own space, so they take the same matrix.
        # ponytail: moving the two ends is exact for the SVG's uniform scales; a skewed group would need the brush transformed instead.
        $gradient = $gradients[[regex]::Match($attributes, 'url\(#([^)]+)\)').Groups[1].Value]
        $ends     = [System.Drawing.PointF[]] $gradient.Ends.Clone()
        $stack.Peek().TransformPoints($ends)
        $path.Transform($stack.Peek())

        [void] $shapes.Add(@{ Path = $path; Ends = $ends; Colors = $gradient.Colors })
    }
    return $shapes
}

# Every shape's outline in one even-odd figure, so inner shapes knock out of outer ones
function New-SilhouettePath($shapes) {
    $silhouette = New-Object System.Drawing.Drawing2D.GraphicsPath
    $silhouette.FillMode = [System.Drawing.Drawing2D.FillMode]::Alternate
    foreach ($shape in $shapes) { $silhouette.AddPath($shape.Path, $false) }
    return $silhouette
}

# A transparent square canvas to draw one frame on
function New-Canvas([int] $size) {
    $bitmap = New-Object System.Drawing.Bitmap $size, $size, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g      = [System.Drawing.Graphics]::FromImage($bitmap)
    $g.SmoothingMode     = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.PixelOffsetMode   = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
    $g.Clear([System.Drawing.Color]::Transparent)
    return @{ Bitmap = $bitmap; Graphics = $g }
}

# Fill the silhouette at one size in one flat color
function Get-SilhouetteFrame($silhouette, [System.Drawing.Color] $color, [int] $size) {
    $canvas = New-Canvas $size

    $frame = $silhouette.Clone()
    $scale = New-Object System.Drawing.Drawing2D.Matrix
    $scale.Scale($size / $viewBox, $size / $viewBox)
    $frame.Transform($scale)

    $brush = New-Object System.Drawing.SolidBrush $color
    $canvas.Graphics.FillPath($brush, $frame)

    $brush.Dispose(); $scale.Dispose(); $frame.Dispose(); $canvas.Graphics.Dispose()
    return $canvas.Bitmap
}

# Draw the colored icon at one size, each shape filled with its gradient
function Get-ColorFrame($shapes, [int] $size) {
    $canvas = New-Canvas $size
    $canvas.Graphics.ScaleTransform($size / $viewBox, $size / $viewBox)

    foreach ($shape in $shapes) {
        # SVG pads past a gradient's ends with the end colors, but GDI+ tiles. So the brush spans
        # three times the gradient, held flat in the outer thirds, which covers every shape here.
        $start = $shape.Ends[0]
        $end   = $shape.Ends[1]
        $dx    = $end.X - $start.X
        $dy    = $end.Y - $start.Y
        $from  = New-Object System.Drawing.PointF ($start.X - $dx), ($start.Y - $dy)
        $to    = New-Object System.Drawing.PointF ($end.X + $dx), ($end.Y + $dy)

        $brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush $from, $to, $shape.Colors[0], $shape.Colors[1]
        $blend = New-Object System.Drawing.Drawing2D.ColorBlend 4
        $blend.Colors    = [System.Drawing.Color[]] @($shape.Colors[0], $shape.Colors[0], $shape.Colors[1], $shape.Colors[1])
        $blend.Positions = [float[]] @(0, (1 / 3), (2 / 3), 1)
        $brush.InterpolationColors = $blend

        $canvas.Graphics.FillPath($brush, $shape.Path)
        $brush.Dispose()
    }

    $canvas.Graphics.Dispose()
    return $canvas.Bitmap
}

# One icon frame as a bottom-up 32bpp DIB: header, BGRA pixels, then an empty AND mask.
# Every tool reads this form; a PNG frame is only safe from Vista on and GDI+ still refuses it.
function Get-FrameDib($bitmap) {
    $size   = $bitmap.Width
    $out    = New-Object System.IO.MemoryStream
    $writer = New-Object System.IO.BinaryWriter $out

    # BITMAPINFOHEADER; the height counts the color rows and the mask rows together
    $writer.Write([uint32] 40)
    $writer.Write([int32] $size)
    $writer.Write([int32] ($size * 2))
    $writer.Write([uint16] 1)             # color planes
    $writer.Write([uint16] 32)            # bits per pixel
    $writer.Write([uint32] 0)             # BI_RGB, no compression
    $writer.Write([uint32] ($size * $size * 4))
    0..3 | ForEach-Object { $writer.Write([uint32] 0) }

    # Pixels, bottom row first
    $rect = New-Object System.Drawing.Rectangle 0, 0, $size, $size
    $data = $bitmap.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $row  = New-Object byte[] ($size * 4)
    for ($y = $size - 1; $y -ge 0; $y--) {
        [System.Runtime.InteropServices.Marshal]::Copy([IntPtr]::Add($data.Scan0, $y * $data.Stride), $row, 0, $row.Length)
        $writer.Write($row)
    }
    $bitmap.UnlockBits($data)

    # AND mask: all zeros, since the alpha channel already carries the transparency. Rows pad to 4 bytes.
    $maskRow = [Math]::Ceiling($size / 32) * 4
    $writer.Write((New-Object byte[] ($maskRow * $size)))

    $writer.Flush()
    $bytes = $out.ToArray()
    $writer.Dispose()

    # The comma keeps PowerShell from unrolling the array into single bytes on the way out
    return ,$bytes
}

# Pack the rendered frames into an .ico file and dispose them
function Save-Ico([string] $file, $bitmaps) {
    $frames = @($bitmaps | ForEach-Object {
        $frame = @{ Size = $_.Width; Data = Get-FrameDib $_ }
        $_.Dispose()
        $frame
    })

    $out    = New-Object System.IO.MemoryStream
    $writer = New-Object System.IO.BinaryWriter $out

    # ICONDIR: reserved, type 1 (icon), frame count
    $writer.Write([uint16] 0)
    $writer.Write([uint16] 1)
    $writer.Write([uint16] $frames.Count)

    # ICONDIRENTRY per frame; 256px is written as 0, and the data follows the directory
    $offset = 6 + (16 * $frames.Count)
    foreach ($frame in $frames) {
        $dimension = if ($frame.Size -ge 256) { 0 } else { $frame.Size }
        $writer.Write([byte] $dimension)      # width
        $writer.Write([byte] $dimension)      # height
        $writer.Write([byte] 0)               # palette entries (none, it is 32bpp)
        $writer.Write([byte] 0)               # reserved
        $writer.Write([uint16] 1)             # color planes
        $writer.Write([uint16] 32)            # bits per pixel
        $writer.Write([uint32] $frame.Data.Length)
        $writer.Write([uint32] $offset)
        $offset += $frame.Data.Length
    }

    foreach ($frame in $frames) { $writer.Write($frame.Data) }

    $writer.Flush()
    [System.IO.File]::WriteAllBytes((Join-Path $dest $file), $out.ToArray())
    $writer.Dispose()
    "wrote $file at $($sizes -join ', ')px"
}

$shapes = Get-SvgShapes (Get-Content (Resolve-Path $svgPath) -Raw)

# Monochrome pair
$silhouette = New-SilhouettePath $shapes
Save-Ico "app-mono-light.ico" @($sizes | ForEach-Object { Get-SilhouetteFrame $silhouette ([System.Drawing.Color]::White) $_ })
Save-Ico "app-mono-dark.ico"  @($sizes | ForEach-Object { Get-SilhouetteFrame $silhouette ([System.Drawing.Color]::Black) $_ })
$silhouette.Dispose()

# Colored icon, and the 512px render the package logos are made from
Save-Ico "app.ico" @($sizes | ForEach-Object { Get-ColorFrame $shapes $_ })
$large = Get-ColorFrame $shapes 512
$large.Save((Join-Path $dest "app-512.png"), [System.Drawing.Imaging.ImageFormat]::Png)
$large.Dispose()
"wrote app-512.png"

$shapes | ForEach-Object { $_.Path.Dispose() }
