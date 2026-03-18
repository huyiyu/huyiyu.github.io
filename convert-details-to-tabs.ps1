# 批量将 <details> 转换为 tab shortcode
# 使用方法: .\convert-details-to-tabs.ps1 -FilePath "content/cn/posts/kubernetes/cka202602.md"

param(
    [Parameter(Mandatory=$true)]
    [string]$FilePath
)

$content = Get-Content -Path $FilePath -Raw -Encoding UTF8

# 正则匹配 <details>...</details> 块
$pattern = '(?s)---?
<details>?
<summary>答案:</summary>?
(.*?)?
</details>'

$count = 0
$newContent = [regex]::Replace($content, $pattern, {
    param($match)
    $count++
    $inner = $match.Groups[1].Value.Trim()
    
    return @"
{{< tabs "题目" "答案" >}}
{{< tab "题目" >}}
[题目内容请手动补充]
{{< /tab >}}
{{< tab "答案" >}}
$inner
{{< /tab >}}
{{< /tabs >}}
"@
})

Set-Content -Path $FilePath -Value $newContent -Encoding UTF8
Write-Host "转换完成，替换了 $count 处" -ForegroundColor Green
