// lib/pages/about_page.dart
//
// 车迷驿 · 关于页面
// 依赖：url_launcher、qr_flutter、package_info_plus（见 pubspec.yaml 说明）
//
// 用法：
//   Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AboutPage()));

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

/// ────────────────────────────────────────────────────────────
/// 应用元信息：发布前把这里替换成真实内容即可，页面无需改动
/// ────────────────────────────────────────────────────────────
class AppMeta {
  const AppMeta._();

  /// 应用名称
  static const String name = '车迷驿';

  /// 标语
  static const String slogan = '为热爱指明方向';

  /// 一句话简介
  static const String intro =
      '一款为铁路爱好者打造的工具箱：查看枢纽配线与机位、记录拍摄与乘车轨迹、'
      '聚合社区与公开数据源的列车信息，让每一次出行都有迹可循。';

  /// 开发者 / 团队
  static const String author = '京局京段SS9G-0047';

  /// 联系邮箱，留空则隐藏该入口
  static const String email = '';

  /// 应用图标资源路径
  static const String? logoAsset = 'lib/assets/icon/logo_1024.png';

  /// GitHub 仓库地址（二维码内容也取自这里）
  static const String repoUrl = 'https://github.com/SS9G-0047/TrainFansFamily';

  /// 反馈 / Issue 地址
  static const String issuesUrl = 'https://github.com/SS9G-0047/TrainFansFamily/issues';

  /// 开源协议名称与地址
  static const String licenseName = 'MIT License';
  static const String licenseUrl =
      'https://github.com/SS9G-0047/TrainFansFamily/blob/main/LICENSE';

  /// 隐私政策地址，留空则隐藏该入口
  static const String privacyUrl = '';

  /// 已发布的平台
  static const List<String> platforms = ['Windows', 'Android'];

  /// 功能模块
  static const List<FeatureInfo> features = [
    FeatureInfo(
      icon: Icons.map_outlined,
      accent: Color(0xFF3B82F6),
      title: '铁路地图预览',
      desc: '查看枢纽配线与机位分布，线路走向、站台布局一目了然。',
    ),
    FeatureInfo(
      icon: Icons.place_outlined,
      accent: Color(0xFF34C759),
      title: '机位记录',
      desc: '收藏并管理你的拍摄机位，一键导航快速到达。',
    ),
    FeatureInfo(
      icon: Icons.search_outlined,
      accent: Color(0xFFF59E0B),
      title: '信息查询',
      desc: '汇聚社区与公开网站的列车数据，车次、时刻一搜即达。',
    ),
    FeatureInfo(
      icon: Icons.alt_route_outlined,
      accent: Color(0xFF8B5CF6),
      title: '行程记录',
      desc: '记录乘车与拍摄轨迹，留下每一段铁路记忆。',
      badge: 'Android',
    ),
  ];
}

/// 功能模块数据
class FeatureInfo {
  const FeatureInfo({
    required this.icon,
    required this.accent,
    required this.title,
    required this.desc,
    this.badge,
  });

  final IconData icon;
  final Color accent;
  final String title;
  final String desc;

  /// 平台角标，如 'Android'、'Windows'，为空则不显示
  final String? badge;
}

/// 关于页面
class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: CustomScrollView(
        slivers: [
          const SliverAppBar.large(title: Text('关于')),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const _HeroCard(),
                  const SizedBox(height: 24),
                  const _SectionTitle('功能'),
                  const SizedBox(height: 10),
                  const _FeatureCard(),
                  const SizedBox(height: 24),
                  const _SectionTitle('开源与反馈'),
                  const SizedBox(height: 10),
                  const _OpenSourceCard(),
                  const SizedBox(height: 12),
                  const _QrCard(),
                  const SizedBox(height: 24),
                  const _SectionTitle('法律与致谢'),
                  const SizedBox(height: 10),
                  const _LegalCard(),
                  const SizedBox(height: 12),
                  const _DisclaimerCard(),
                  const SizedBox(height: 28),
                  const _Footer(),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// ── 顶部：图标 + 名称 + 版本 + 标语 ──────────────────────────
class _HeroCard extends StatelessWidget {
  const _HeroCard();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          // 背景：铁路曲线 + 绿色节点（呼应品牌视觉，纯绘制无资源依赖）
          const Positioned.fill(child: CustomPaint(painter: _RailCurvePainter())),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
            child: Column(
              children: [
                _AppLogo(),
                const SizedBox(height: 16),
                Text(
                  AppMeta.name,
                  textAlign: TextAlign.center,
                  style: tt.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 6),
                const _VersionText(),
                const SizedBox(height: 10),
                Text(
                  AppMeta.slogan,
                  textAlign: TextAlign.center,
                  style: tt.titleSmall?.copyWith(
                    color: cs.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  AppMeta.intro,
                  textAlign: TextAlign.center,
                  style: tt.bodyMedium?.copyWith(
                    color: cs.onSurfaceVariant,
                    height: 1.6,
                  ),
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  alignment: WrapAlignment.center,
                  children: [
                    for (final p in AppMeta.platforms)
                      _Chip(
                        icon: switch (p) {
                          'Windows' => Icons.desktop_windows_outlined,
                          _ => Icons.android_outlined,
                        },
                        label: p,
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AppLogo extends StatelessWidget {
  const _AppLogo();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    Widget child;
    if (AppMeta.logoAsset != null) {
      child = ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: Image.asset(AppMeta.logoAsset!, width: 72, height: 72),
      );
    } else {
      child = Container(
        width: 72,
        height: 72,
        decoration: BoxDecoration(
          color: cs.primary,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Icon(Icons.directions_railway_rounded,
            color: cs.onPrimary, size: 36),
      );
    }

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: cs.primary.withOpacity(0.28),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: child,
    );
  }
}

/// 版本号（异步读取，失败时静默隐藏）
class _VersionText extends StatelessWidget {
  const _VersionText();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return FutureBuilder<PackageInfo>(
      future: PackageInfo.fromPlatform(),
      builder: (context, snapshot) {
        final info = snapshot.data;
        final text = info == null
            ? ''
            : 'v${info.version}  ·  build ${info.buildNumber}';
        return AnimatedOpacity(
          opacity: info == null ? 0 : 1,
          duration: const Duration(milliseconds: 300),
          child: Text(
            text,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: cs.onSurfaceVariant,
                  letterSpacing: 0.4,
                ),
          ),
        );
      },
    );
  }
}

/// ── 分区标题 ────────────────────────────────────────────────
class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Text(
        text,
        style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: cs.primary,
              fontWeight: FontWeight.w700,
            ),
      ),
    );
  }
}

/// ── 功能列表 ────────────────────────────────────────────────
class _FeatureCard extends StatelessWidget {
  const _FeatureCard();

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          for (int i = 0; i < AppMeta.features.length; i++) ...[
            if (i > 0) const Divider(height: 1, indent: 76),
            _FeatureTile(AppMeta.features[i]),
          ],
        ],
      ),
    );
  }
}

class _FeatureTile extends StatelessWidget {
  const _FeatureTile(this.feature);

  final FeatureInfo feature;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: feature.accent.withOpacity(0.14),
              borderRadius: BorderRadius.circular(13),
            ),
            child: Icon(feature.icon, color: feature.accent, size: 22),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        feature.title,
                        style: tt.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                      ),
                    ),
                    if (feature.badge != null) ...[
                      const SizedBox(width: 8),
                      _Chip(
                        label: feature.badge!,
                        icon: Icons.android_outlined,
                        color: feature.accent,
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  feature.desc,
                  style: tt.bodySmall?.copyWith(
                    color: cs.onSurfaceVariant,
                    height: 1.55,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// ── 开源与反馈 ──────────────────────────────────────────────
class _OpenSourceCard extends StatelessWidget {
  const _OpenSourceCard();

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          _LinkTile(
            icon: Icons.code_rounded,
            title: 'GitHub 仓库',
            subtitle: AppMeta.repoUrl,
            url: AppMeta.repoUrl,
          ),
          const Divider(height: 1),
          _LinkTile(
            icon: Icons.bug_report_outlined,
            title: '反馈问题',
            subtitle: '提交 Bug 或功能建议',
            url: AppMeta.issuesUrl,
          ),
          if (AppMeta.email.isNotEmpty) ...[
            const Divider(height: 1),
            _LinkTile(
              icon: Icons.mail_outline_rounded,
              title: '邮件联系',
              subtitle: AppMeta.email,
              url: 'mailto:${AppMeta.email}',
            ),
          ],
        ],
      ),
    );
  }
}

/// ── 仓库二维码 ──────────────────────────────────────────────
class _QrCard extends StatelessWidget {
  const _QrCard();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 22, horizontal: 20),
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(14),
              ),
              child: QrImageView(
                data: AppMeta.repoUrl,
                version: QrVersions.auto,
                size: 132,
                backgroundColor: Colors.white,
                padding: EdgeInsets.zero,
              ),
            ),
            const SizedBox(height: 14),
            Text(
              '扫码访问开源仓库',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}

/// ── 法律与致谢 ──────────────────────────────────────────────
class _LegalCard extends StatelessWidget {
  const _LegalCard();

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          _ActionTile(
            icon: Icons.description_outlined,
            title: '第三方开源许可',
            subtitle: 'Flutter 及依赖库的许可证',
            onTap: () => showLicensePage(
              context: context,
              applicationName: AppMeta.name,
              applicationVersion: '',
              applicationLegalese: '© ${DateTime.now().year} ${AppMeta.author}',
            ),
          ),
          // const Divider(height: 1),
          // _LinkTile(
          //   icon: Icons.gavel_rounded,
          //   title: '本项目许可',
          //   subtitle: AppMeta.licenseName,
          //   url: AppMeta.licenseUrl,
          // ),
          // if (AppMeta.privacyUrl.isNotEmpty) ...[
          //   const Divider(height: 1),
          //   _LinkTile(
          //     icon: Icons.privacy_tip_outlined,
          //     title: '隐私政策',
          //     subtitle: '我们如何收集与使用数据',
          //     url: AppMeta.privacyUrl,
          //   ),
          // ],
        ],
      ),
    );
  }
}

/// ── 数据来源与免责声明 ──────────────────────────────────────
class _DisclaimerCard extends StatelessWidget {
  const _DisclaimerCard();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Card(
      color: cs.primaryContainer.withOpacity(0.35),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.info_outline_rounded, size: 20, color: cs.onSurfaceVariant),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                '站内列车时刻、车次与配线数据来自铁路爱好者社区及公开网站，'
                '可能存在延迟或误差，仅供兴趣交流与出行参考，'
                '不构成任何购票或乘车依据，请以 12306 及车站公告为准。',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: cs.onSurfaceVariant,
                      height: 1.6,
                    ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// ── 页脚 ────────────────────────────────────────────────────
class _Footer extends StatelessWidget {
  const _Footer();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      children: [
        Text(
          '© ${DateTime.now().year} ${AppMeta.author}',
          style: Theme.of(context)
              .textTheme
              .bodySmall
              ?.copyWith(color: cs.onSurfaceVariant),
        ),
        const SizedBox(height: 6),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.favorite_rounded, size: 12, color: cs.primary),
            const SizedBox(width: 4),
            Text(
              'Made with Flutter',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: cs.onSurfaceVariant),
            ),
          ],
        ),
      ],
    );
  }
}

/// ── 通用小部件 ──────────────────────────────────────────────
class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.icon, this.color});

  final String label;
  final IconData icon;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final c = color ?? cs.primary;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: c.withOpacity(0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: c),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: c,
            ),
          ),
        ],
      ),
    );
  }
}

class _LinkTile extends StatelessWidget {
  const _LinkTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.url,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final String url;

  @override
  Widget build(BuildContext context) {
    return _ActionTile(
      icon: icon,
      title: title,
      subtitle: subtitle,
      onTap: () => _launch(context, url),
    );
  }
}

class _ActionTile extends StatelessWidget {
  const _ActionTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    return ListTile(
      onTap: onTap,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      leading: Icon(icon, size: 22, color: cs.onSurfaceVariant),
      title: Text(title, style: tt.bodyMedium?.copyWith(fontWeight: FontWeight.w500)),
      subtitle: subtitle.isEmpty
          ? null
          : Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            ),
      trailing: Icon(Icons.chevron_right_rounded, size: 20, color: cs.outlineVariant),
    );
  }
}

/// 打开外链
Future<void> _launch(BuildContext context, String url) async {
  final uri = Uri.parse(url);
  try {
    final ok = await canLaunchUrl(uri);
    if (ok) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
      return;
    }
  } catch (_) {
    // 忽略，统一走下方提示
  }
  if (context.mounted) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('无法打开链接：$url')));
  }
}

/// ── 背景绘制：铁路曲线 + 节点 ────────────────────────────────
class _RailCurvePainter extends CustomPainter {
  const _RailCurvePainter();

  static const _nodeColor = Color(0xFF34C759);

  @override
  void paint(Canvas canvas, Size size) {
    final curve = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..strokeCap = StrokeCap.round
      ..color = _nodeColor.withOpacity(0.35);

    final path = Path()
      ..moveTo(-10, size.height * 0.78)
      ..cubicTo(
        size.width * 0.25, size.height * 0.62,
        size.width * 0.55, size.height * 1.02,
        size.width + 10, size.height * 0.42,
      );

    canvas.drawPath(_dashPath(path, dash: 7, gap: 6), curve);

    final node = Paint()..color = _nodeColor.withOpacity(0.55);
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..color = _nodeColor.withOpacity(0.5);

    const points = [0.16, 0.48, 0.84];
    for (int i = 0; i < points.length; i++) {
      final t = points[i];
      final metric = path.computeMetrics().first;
      final pos = metric.getTangentForOffset(metric.length * t)!.position;
      final r = i == 1 ? 5.5 : 4.0;
      canvas.drawCircle(pos, r, node);
      canvas.drawCircle(pos, r + 4, ring);
    }
  }

  /// 把实线路径转成虚线
  Path _dashPath(Path source, {required double dash, required double gap}) {
    final dest = Path();
    for (final metric in source.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        final next = (distance + dash).clamp(0.0, metric.length);
        dest.addPath(metric.extractPath(distance, next), Offset.zero);
        distance = next + gap;
      }
    }
    return dest;
  }

  @override
  bool shouldRepaint(covariant _RailCurvePainter oldDelegate) => false;
}
