import 'package:flutter/material.dart';

class AboutUs extends StatelessWidget {
  const AboutUs({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('About Us'),
        titleTextStyle: const TextStyle(
          color: Colors.red,
          fontSize: 30,
          fontWeight: FontWeight.bold,
        ),
        iconTheme: const IconThemeData(color: Colors.red),
        elevation: 0,
      ),
      body: SingleChildScrollView(
        child: Center(
          child: Container(
            constraints: const BoxConstraints(maxWidth: 1000),
            margin: const EdgeInsets.all(16),
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(20), // Rounded edges
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.05),
                  blurRadius: 8,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Column(
              children: [
                // Banner Image
                ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: Image.asset(
                    'assets/images/banner.png',
                    height: 240,
                    width: double.infinity,
                    fit: BoxFit.cover,
                  ),
                ),
                const SizedBox(height: 20),

                // Mission & Vision stacked
                _buildSectionCard(
                  icon: Icons.flag,
                  title: 'Our Mission',
                  content:
                  'Lorem ipsum dolor sit amet, consectetur adipiscing elit. '
                      'Curabitur blandit tempus porttitor. Sed posuere consectetur est at lobortis. '
                      'Maecenas faucibus mollis interdum. Nullam quis risus eget urna mollis ornare vel eu leo. '
                      'Lorem ipsum dolor sit amet, consectetur adipiscing elit.'
                      'Lorem ipsum dolor sit amet, consectetur adipiscing elit. '
                      'Curabitur blandit tempus porttitor. Sed posuere consectetur est at lobortis. '
                      'Maecenas faucibus mollis interdum. Nullam quis risus eget urna mollis ornare vel eu leo. '
                      'Lorem ipsum dolor sit amet, consectetur adipiscing elit.',

                ),
                const SizedBox(height: 20),

                _buildSectionCard(
                  icon: Icons.visibility,
                  title: 'Our Vision',
                  content:
                  'Lorem ipsum dolor sit amet, consectetur adipiscing elit. '
                      'Integer posuere erat a ante venenatis dapibus posuere velit aliquet. '
                      'Aenean eu leo quam. Pellentesque ornare sem lacinia quam venenatis vestibulum. '
                      'Curabitur blandit tempus porttitor. Sed posuere consectetur est at lobortis.'
                      'Lorem ipsum dolor sit amet, consectetur adipiscing elit. '
                      'Curabitur blandit tempus porttitor. Sed posuere consectetur est at lobortis. '
                      'Maecenas faucibus mollis interdum. Nullam quis risus eget urna mollis ornare vel eu leo. '
                      'Lorem ipsum dolor sit amet, consectetur adipiscing elit.',
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSectionCard({
    required IconData icon,
    required String title,
    required String content,
  }) {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: Colors.blueAccent, size: 28),
                const SizedBox(width: 10),
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    color: Colors.blueAccent,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              content,
              style: const TextStyle(fontSize: 16, height: 1.5),
            ),
          ],
        ),
      ),
    );
  }
}
