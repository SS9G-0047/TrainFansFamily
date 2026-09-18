import 'package:flutter/material.dart';

Widget buildWarningText(String source, BuildContext context) {
  final bool isDark = Theme.of(context).brightness == Brightness.dark;
  late Color labelColor;
  late Color contentColor;
  if (isDark) {
    labelColor = const Color(0xFF992222);
    contentColor = Colors.black;
  } else {
    labelColor = const Color(0xFF48BB78);
    contentColor = Colors.white;
  }

  if (!source.contains("：")) {
    return Text(
      source,
      style: TextStyle(
        color: contentColor,
        fontSize: 19.5,
        height: 1.3,
        fontWeight: FontWeight.bold,
      ),
    );
  }
  final arr = source.split("：");
  return RichText(
    text: TextSpan(
      children: [
        TextSpan(
          text: "${arr[0]}：",
          style: TextStyle(
            color: labelColor,
            fontWeight: FontWeight.bold,
            fontSize: 13.5,
          ),
        ),
        TextSpan(
          text: arr[1],
          style: TextStyle(
            color: contentColor,
            fontWeight: FontWeight.bold,
            fontSize: 13.5,
          ),
        ),
      ],
    ),
  );
}

Widget buildWarningPanel(BuildContext context, List<String> warningList) {
  final scheme = Theme.of(context).colorScheme;
  final bool isDarkMode = Theme.of(context).brightness == Brightness.dark;
  final Color reverseBg = scheme.onPrimaryContainer;
  final Color headerIconColor = isDarkMode ? const Color(0xFF992222) : const Color(0xFF48BB78);

  return Container(
    width: double.infinity,
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    decoration: BoxDecoration(
      color: reverseBg,
      borderRadius: BorderRadius.circular(8),
      boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 2, offset: Offset(1, 1))],
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.warning_amber, color: headerIconColor, size: 22),
            const SizedBox(width: 6),
            Text(
              "实时行车预警信息",
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: headerIconColor,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        ...warningList.map(
          (msg) => Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: buildWarningText(msg, context),
          ),
        )
      ],
    ),
  );
}
