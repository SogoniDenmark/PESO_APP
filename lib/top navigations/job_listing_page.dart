import 'dart:math';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../main_homepage.dart';

class JobsPage extends StatefulWidget {
  const JobsPage({super.key});

  @override
  State<JobsPage> createState() => _JobsPageState();
}

class _JobsPageState extends State<JobsPage> {
  final TextEditingController _searchController = TextEditingController();
  String? _selectedBarangay;
  String? _selectedEmploymentType;
  String? _selectedEducationLevel;
  bool _pwdOnly = false;
  bool _spesOnly = false;
  bool _mipOnly = false;
  bool _showRecommended = true;

  final List<String> barangays = [
    'Barangays', 'Poblacion', 'Bel-Air', 'San Antonio', 'Guadalupe Nuevo',
    'Cembo', 'West Rembo', 'Tejeros', 'Rizal',
  ];

  final List<String> employmentTypes = [
    'Employment Type', 'Contractual', 'Permanent', 'Project-based', 'Work from home'
  ];

  final List<String> educationLevels = [
    'Education Level', 'High School', 'College Graduate', "Master's", 'Doctorate'
  ];

  User? currentUser;
  List<String> appliedJobIds = [];
  Map<String, dynamic>? userProfile;
  Map<String, double> jobMatchScores = {};
  Map<String, Map<String, dynamic>> jobMatchDetails = {};

  // For TF-IDF calculation across all documents
  Map<String, double> _idfScores = {};
  List<Map<String, dynamic>> _allJobs = [];

  @override
  void initState() {
    super.initState();
    currentUser = FirebaseAuth.instance.currentUser;
    _loadUserData();
  }

  Future<void> _loadUserData() async {
    if (currentUser == null) return;
    
    final userDoc = await FirebaseFirestore.instance
        .collection('users')
        .doc(currentUser!.uid)
        .get();
    
    if (userDoc.exists) {
      final data = userDoc.data();
      final List<dynamic> appliedJobsData = data?['appliedJobs'] ?? [];
      setState(() {
        appliedJobIds = appliedJobsData
            .map<String>((entry) {
              if (entry is Map<String, dynamic>) return entry['jobId'] ?? '';
              return '';
            })
            .where((id) => id.isNotEmpty)
            .toList();
      });
    }

    final profileDoc = await FirebaseFirestore.instance
        .collection('users')
        .doc(currentUser!.uid)
        .collection('forms')
        .doc('jobseeker_registration')
        .get();

    if (profileDoc.exists) {
      setState(() {
        userProfile = profileDoc.data();
      });
    }
  }

  // ============================================================
  // 1. TF-IDF & COSINE SIMILARITY
  // ============================================================

  /// Calculate Term Frequency for a document
  Map<String, double> _calculateTF(List<String> words) {
    Map<String, int> wordCount = {};
    for (var word in words) {
      wordCount[word] = (wordCount[word] ?? 0) + 1;
    }
    
    Map<String, double> tf = {};
    for (var entry in wordCount.entries) {
      tf[entry.key] = entry.value / words.length;
    }
    return tf;
  }

  /// Calculate Inverse Document Frequency across all jobs
  void _calculateIDF(List<Map<String, dynamic>> jobs) {
    Map<String, int> documentFrequency = {};
    int totalDocs = jobs.length + 1; // +1 for user profile

    // Count document frequency for each term
    for (var job in jobs) {
      Set<String> uniqueTerms = _extractAllJobWords(job).toSet();
      for (var term in uniqueTerms) {
        documentFrequency[term] = (documentFrequency[term] ?? 0) + 1;
      }
    }

    // Add user profile terms
    Set<String> userTerms = _extractAllUserProfileWords().toSet();
    for (var term in userTerms) {
      documentFrequency[term] = (documentFrequency[term] ?? 0) + 1;
    }

    // Calculate IDF: log(N / df)
    _idfScores = {};
    for (var entry in documentFrequency.entries) {
      _idfScores[entry.key] = log(totalDocs / (entry.value + 1));
    }
  }

  /// Calculate TF-IDF vector for a document
  Map<String, double> _calculateTFIDF(List<String> words) {
    Map<String, double> tf = _calculateTF(words);
    Map<String, double> tfidf = {};
    
    for (var entry in tf.entries) {
      double idf = _idfScores[entry.key] ?? 0.0;
      tfidf[entry.key] = entry.value * idf;
    }
    return tfidf;
  }

  /// Calculate Cosine Similarity between two TF-IDF vectors
  double _cosineSimilarity(Map<String, double> vec1, Map<String, double> vec2) {
    Set<String> allKeys = {...vec1.keys, ...vec2.keys};
    
    double dotProduct = 0.0;
    double norm1 = 0.0;
    double norm2 = 0.0;
    
    for (var key in allKeys) {
      double v1 = vec1[key] ?? 0.0;
      double v2 = vec2[key] ?? 0.0;
      dotProduct += v1 * v2;
      norm1 += v1 * v1;
      norm2 += v2 * v2;
    }
    
    if (norm1 == 0 || norm2 == 0) return 0.0;
    return dotProduct / (sqrt(norm1) * sqrt(norm2));
  }

  /// Get TF-IDF Cosine Similarity score (0-100)
  double _getTFIDFScore(Map<String, dynamic> job) {
    List<String> userWords = _extractAllUserProfileWords().toList();
    List<String> jobWords = _extractAllJobWords(job).toList();
    
    if (userWords.isEmpty || jobWords.isEmpty) return 0.0;

    Map<String, double> userTFIDF = _calculateTFIDF(userWords);
    Map<String, double> jobTFIDF = _calculateTFIDF(jobWords);
    
    double similarity = _cosineSimilarity(userTFIDF, jobTFIDF);
    return similarity * 100;
  }

  // ============================================================
  // 2. RULE-BASED FILTERING
  // ============================================================

  Map<String, dynamic> _applyRuleBasedFiltering(Map<String, dynamic> job) {
    double score = 0.0;
    List<String> matchedRules = [];
    List<String> unmatchedRules = [];

    // Rule 1: Education Level Match (20 points)
    int userEduLevel = _getUserEducationLevel();
    int requiredEduLevel = _getRequiredEducationLevel(job['educationLevel']?.toString() ?? '');
    
    if (requiredEduLevel == 0 || userEduLevel >= requiredEduLevel) {
      score += 20;
      matchedRules.add('Education: Qualified');
    } else {
      unmatchedRules.add('Education: Underqualified');
    }

    // Rule 2: Location Match (15 points)
    String userBarangay = _normalizeText(userProfile?['barangay']?.toString() ?? '');
    String jobLocation = _normalizeText(job['location']?.toString() ?? '');
    List<String> prefLocations = _safeGetList(userProfile?['preferredWorkLocations'])
        .map((l) => _normalizeText(l?.toString() ?? ''))
        .where((l) => l.isNotEmpty)
        .toList();

    if (jobLocation.isEmpty || jobLocation == 'barangays') {
      score += 10;
      matchedRules.add('Location: Any');
    } else if (jobLocation == userBarangay) {
      score += 15;
      matchedRules.add('Location: Exact match');
    } else if (prefLocations.any((p) => p.contains(jobLocation) || jobLocation.contains(p))) {
      score += 12;
      matchedRules.add('Location: Preferred area');
    } else {
      score += 5;
      unmatchedRules.add('Location: Different area');
    }

    // Rule 3: Employment Type Preference (15 points)
    String jobType = _normalizeText(job['employmentType']?.toString() ?? '');
    bool wantsFullTime = userProfile?['fullTime'] == true;
    bool wantsPartTime = userProfile?['partTime'] == true;

    if (jobType == 'permanent' && wantsFullTime) {
      score += 15;
      matchedRules.add('Employment: Full-time match');
    } else if ((jobType == 'contractual' || jobType == 'project-based') && wantsPartTime) {
      score += 15;
      matchedRules.add('Employment: Part-time match');
    } else if (jobType == 'work from home') {
      score += 12;
      matchedRules.add('Employment: Remote work');
    } else {
      score += 5;
      unmatchedRules.add('Employment: Type mismatch');
    }

    // Rule 4: PWD Accommodation (20 points if applicable)
    bool isPWD = userProfile?['isPWD'] == true || 
                 (userProfile?['disabilityType']?.toString().isNotEmpty == true);
    if (isPWD) {
      if (job['isPWD'] == true) {
        score += 20;
        matchedRules.add('PWD: Accommodating employer');
      } else {
        unmatchedRules.add('PWD: No accommodation listed');
      }
    } else {
      score += 10; // Neutral score for non-PWD
    }

    // Rule 5: SPES Program Match (15 points if applicable)
    bool is4Ps = userProfile?['is4Ps'] == true;
    bool isStudent = _normalizeText(userProfile?['employmentStatus']?.toString() ?? '')
        .contains('student');
    
    if (is4Ps || isStudent) {
      if (job['isSPES'] == true) {
        score += 15;
        matchedRules.add('SPES: Program eligible');
      } else {
        score += 5;
        unmatchedRules.add('SPES: Not a SPES job');
      }
    } else {
      score += 7;
    }

    // Rule 6: Experience Level Match (15 points)
    String jobTitle = _normalizeText(job['title']?.toString() ?? '');
    String jobDesc = _normalizeText(job['description']?.toString() ?? '');
    int totalExpMonths = _getTotalExperienceMonths();
    
    bool isEntryLevel = jobTitle.contains('entry') || jobTitle.contains('junior') ||
        jobDesc.contains('fresh graduate') || jobDesc.contains('no experience');
    bool isSeniorLevel = jobTitle.contains('senior') || jobTitle.contains('lead') ||
        jobTitle.contains('manager') || jobDesc.contains('5 years');

    if (isEntryLevel && totalExpMonths < 24) {
      score += 15;
      matchedRules.add('Experience: Entry-level match');
    } else if (isSeniorLevel && totalExpMonths >= 60) {
      score += 15;
      matchedRules.add('Experience: Senior-level match');
    } else if (!isEntryLevel && !isSeniorLevel) {
      score += 12;
      matchedRules.add('Experience: Mid-level');
    } else {
      score += 5;
      unmatchedRules.add('Experience: Level mismatch');
    }

    return {
      'score': score,
      'maxScore': 100.0,
      'percentage': (score / 100) * 100,
      'matchedRules': matchedRules,
      'unmatchedRules': unmatchedRules,
    };
  }

  int _getTotalExperienceMonths() {
    final workExp = _safeGetList(userProfile?['workExperiences']);
    int total = 0;
    for (var exp in workExp) {
      if (exp is Map<String, dynamic>) {
        total += int.tryParse(exp['months']?.toString() ?? '0') ?? 0;
      }
    }
    return total;
  }

  int _getUserEducationLevel() {
    if (userProfile?['graduateStudies']?.toString().isNotEmpty == true) return 4;
    if (userProfile?['tertiary']?.toString().isNotEmpty == true) return 2;
    if (userProfile?['secondary']?.toString().isNotEmpty == true) return 1;
    return 1;
  }

  int _getRequiredEducationLevel(String education) {
    String edu = _normalizeText(education);
    if (edu.contains('doctorate')) return 4;
    if (edu.contains('master')) return 3;
    if (edu.contains('college') || edu.contains('bachelor')) return 2;
    if (edu.contains('high school')) return 1;
    return 0;
  }

  // ============================================================
  // 3. HIERARCHICAL CLUSTERING + K-MEANS
  // ============================================================

  /// Assign job to a cluster based on job characteristics
  int _assignJobCluster(Map<String, dynamic> job) {
    // Feature extraction for clustering
    double salaryMin = (job['salaryMin'] as num?)?.toDouble() ?? 0;
    double salaryMax = (job['salaryMax'] as num?)?.toDouble() ?? 0;
    double avgSalary = (salaryMin + salaryMax) / 2;
    
    int eduLevel = _getRequiredEducationLevel(job['educationLevel']?.toString() ?? '');
    
    String jobType = _normalizeText(job['employmentType']?.toString() ?? '');
    int typeScore = jobType == 'permanent' ? 3 : (jobType == 'contractual' ? 2 : 1);
    
    bool isPWD = job['isPWD'] == true;
    bool isSPES = job['isSPES'] == true;
    bool isMIP = job['isMIP'] == true;
    
    // K-Means inspired clustering (5 clusters)
    // Cluster 0: Entry-level, low salary
    // Cluster 1: Mid-level, moderate salary
    // Cluster 2: Senior-level, high salary
    // Cluster 3: Special programs (PWD/SPES/MIP)
    // Cluster 4: Remote/Flexible work

    if (isPWD || isSPES || isMIP) return 3;
    if (jobType == 'work from home') return 4;
    
    if (avgSalary > 50000 || eduLevel >= 3) return 2;
    if (avgSalary > 25000 || eduLevel == 2) return 1;
    return 0;
  }

  /// Assign user to a cluster based on profile
  int _assignUserCluster() {
    if (userProfile == null) return 0;

    bool isPWD = userProfile?['isPWD'] == true || 
                 (userProfile?['disabilityType']?.toString().isNotEmpty == true);
    bool is4Ps = userProfile?['is4Ps'] == true;
    
    if (isPWD || is4Ps) return 3;
    
    int eduLevel = _getUserEducationLevel();
    int expMonths = _getTotalExperienceMonths();
    
    // Check for remote preference
    final prefLocations = _safeGetList(userProfile?['preferredWorkLocations']);
    bool prefersRemote = prefLocations.any((l) => 
        _normalizeText(l?.toString() ?? '').contains('remote') ||
        _normalizeText(l?.toString() ?? '').contains('home'));
    
    if (prefersRemote) return 4;
    if (eduLevel >= 3 || expMonths >= 60) return 2;
    if (eduLevel == 2 || expMonths >= 24) return 1;
    return 0;
  }

  /// Calculate cluster match score
  double _getClusterScore(Map<String, dynamic> job) {
    int jobCluster = _assignJobCluster(job);
    int userCluster = _assignUserCluster();
    
    // Same cluster = 100%, adjacent cluster = 70%, else = 40%
    if (jobCluster == userCluster) return 100.0;
    if ((jobCluster - userCluster).abs() == 1) return 70.0;
    
    // Special case: PWD/SPES cluster matches with entry-level
    if ((jobCluster == 3 && userCluster == 0) || (jobCluster == 0 && userCluster == 3)) {
      return 60.0;
    }
    
    return 40.0;
  }

  /// Get cluster name for display
  String _getClusterName(int cluster) {
    switch (cluster) {
      case 0: return 'Entry-Level';
      case 1: return 'Mid-Level';
      case 2: return 'Senior-Level';
      case 3: return 'Special Programs';
      case 4: return 'Remote/Flexible';
      default: return 'Unknown';
    }
  }

  // ============================================================
  // 4. VADER SENTIMENT ANALYZER
  // ============================================================

  /// VADER-inspired sentiment analysis for job descriptions
  Map<String, dynamic> _analyzeJobSentiment(Map<String, dynamic> job) {
    String text = '${job['title'] ?? ''} ${job['description'] ?? ''} ${job['requirements'] ?? ''}';
    text = _normalizeText(text);

    // Positive words (job-specific)
    final positiveWords = {
      'opportunity': 2.0, 'growth': 2.0, 'career': 1.5, 'benefits': 2.0,
      'competitive': 1.5, 'dynamic': 1.0, 'innovative': 1.5, 'excellent': 2.0,
      'supportive': 1.5, 'flexible': 2.0, 'bonus': 2.0, 'incentive': 1.5,
      'training': 1.5, 'development': 1.5, 'advancement': 2.0, 'team': 1.0,
      'collaborative': 1.5, 'inclusive': 2.0, 'diverse': 1.5, 'rewarding': 2.0,
      'exciting': 1.5, 'challenging': 1.0, 'impactful': 1.5, 'meaningful': 1.5,
      'professional': 1.0, 'motivated': 1.0, 'passionate': 1.5, 'leader': 1.5,
      'insurance': 1.5, 'healthcare': 1.5, 'vacation': 1.5, 'remote': 1.5,
      'hybrid': 1.0, 'wellness': 1.5, 'balance': 2.0, 'friendly': 1.0,
    };

    // Negative words (job-specific)
    final negativeWords = {
      'required': -0.5, 'must': -0.5, 'mandatory': -1.0, 'strict': -1.5,
      'pressure': -1.5, 'overtime': -1.0, 'demanding': -1.0, 'stressful': -2.0,
      'minimum': -0.5, 'only': -0.5, 'immediately': -0.5, 'urgent': -1.0,
      'probation': -0.5, 'contract': -0.5, 'temporary': -1.0, 'no experience': 0.5,
    };

    // Intensifiers
    final intensifiers = {'very': 1.5, 'highly': 1.5, 'extremely': 2.0, 'really': 1.3};

    List<String> words = text.split(RegExp(r'\s+'));
    double positiveScore = 0.0;
    double negativeScore = 0.0;
    int positiveCount = 0;
    int negativeCount = 0;
    List<String> positiveMatches = [];
    List<String> negativeMatches = [];

    double intensifier = 1.0;
    for (int i = 0; i < words.length; i++) {
      String word = words[i];
      
      // Check for intensifiers
      if (intensifiers.containsKey(word)) {
        intensifier = intensifiers[word]!;
        continue;
      }

      // Check positive words
      if (positiveWords.containsKey(word)) {
        double score = positiveWords[word]! * intensifier;
        positiveScore += score;
        positiveCount++;
        positiveMatches.add(word);
      }

      // Check negative words
      if (negativeWords.containsKey(word)) {
        double score = negativeWords[word]!.abs() * intensifier;
        negativeScore += score;
        negativeCount++;
        negativeMatches.add(word);
      }

      intensifier = 1.0; // Reset intensifier
    }

    // Compound score (-1 to 1, normalized)
    double totalScore = positiveScore - negativeScore;
    double maxPossible = max(positiveScore + negativeScore, 1.0);
    double compound = totalScore / maxPossible;
    
    // Normalize to 0-100 scale (neutral = 50)
    double normalizedScore = (compound + 1) * 50;

    return {
      'compound': compound,
      'positive': positiveScore,
      'negative': negativeScore,
      'normalizedScore': normalizedScore,
      'positiveWords': positiveMatches,
      'negativeWords': negativeMatches,
      'sentiment': compound > 0.2 ? 'Positive' : (compound < -0.2 ? 'Negative' : 'Neutral'),
    };
  }

  // ============================================================
  // COMBINED SCORING ALGORITHM
  // ============================================================

  Map<String, dynamic> calculateComprehensiveMatch(Map<String, dynamic> job) {
    if (userProfile == null) {
      return {'totalScore': 0.0, 'breakdown': {}};
    }

    // 1. TF-IDF Cosine Similarity (35% weight)
    double tfidfScore = _getTFIDFScore(job);

    // 2. Rule-Based Filtering (30% weight)
    Map<String, dynamic> ruleResult = _applyRuleBasedFiltering(job);
    double ruleScore = ruleResult['percentage'] as double;

    // 3. Hierarchical Clustering + K-Means (20% weight)
    double clusterScore = _getClusterScore(job);
    int jobCluster = _assignJobCluster(job);
    int userCluster = _assignUserCluster();

    // 4. VADER Sentiment Analysis (15% weight)
    Map<String, dynamic> sentimentResult = _analyzeJobSentiment(job);
    double sentimentScore = sentimentResult['normalizedScore'] as double;

    // Weighted combination
    double totalScore = (tfidfScore * 0.35) + 
                        (ruleScore * 0.30) + 
                        (clusterScore * 0.20) + 
                        (sentimentScore * 0.15);

    return {
      'totalScore': totalScore.clamp(0.0, 100.0),
      'breakdown': {
        'tfidf': {
          'score': tfidfScore,
          'weight': '35%',
          'description': 'Content Similarity',
        },
        'ruleBased': {
          'score': ruleScore,
          'weight': '30%',
          'matchedRules': ruleResult['matchedRules'],
          'unmatchedRules': ruleResult['unmatchedRules'],
          'description': 'Qualification Match',
        },
        'clustering': {
          'score': clusterScore,
          'weight': '20%',
          'jobCluster': _getClusterName(jobCluster),
          'userCluster': _getClusterName(userCluster),
          'description': 'Career Level Match',
        },
        'sentiment': {
          'score': sentimentScore,
          'weight': '15%',
          'sentiment': sentimentResult['sentiment'],
          'positiveWords': sentimentResult['positiveWords'],
          'negativeWords': sentimentResult['negativeWords'],
          'description': 'Job Appeal Score',
        },
      },
    };
  }

  // ============================================================
  // HELPER FUNCTIONS
  // ============================================================

  List<dynamic> _safeGetList(dynamic value) {
    if (value == null) return [];
    if (value is List) return value;
    if (value is Map) return value.values.toList();
    return [];
  }

  Set<String> _extractAllUserProfileWords() {
    Set<String> words = {};
    if (userProfile == null) return words;

    // Skills
    final otherSkills = userProfile!['otherSkills'];
    if (otherSkills is Map<String, dynamic>) {
      otherSkills.forEach((skill, hasSkill) {
        if (hasSkill == true && skill != 'Others') {
          words.addAll(_tokenize(skill));
        }
      });
    } else if (otherSkills is List) {
      for (var skill in otherSkills) {
        words.addAll(_tokenize(skill?.toString() ?? ''));
      }
    }

    // Work experience
    final workExp = _safeGetList(userProfile!['workExperiences']);
    for (var exp in workExp) {
      if (exp is Map<String, dynamic>) {
        words.addAll(_tokenize(exp['position']?.toString() ?? ''));
        words.addAll(_tokenize(exp['companyName']?.toString() ?? ''));
      }
    }

    // Trainings
    final trainings = _safeGetList(userProfile!['trainings']);
    for (var training in trainings) {
      if (training is Map<String, dynamic>) {
        words.addAll(_tokenize(training['course']?.toString() ?? ''));
      }
    }

    // Preferred occupations
    final prefOcc = _safeGetList(userProfile!['preferredOccupations']);
    for (var occ in prefOcc) {
      words.addAll(_tokenize(occ?.toString() ?? ''));
    }

    // Education
    words.addAll(_tokenize(userProfile!['tertiary']?.toString() ?? ''));
    words.addAll(_tokenize(userProfile!['course']?.toString() ?? ''));
    words.addAll(_tokenize(userProfile!['graduateStudies']?.toString() ?? ''));

    // Eligibility
    final eligibility = _safeGetList(userProfile!['eligibility']);
    for (var elig in eligibility) {
      if (elig is Map<String, dynamic>) {
        words.addAll(_tokenize(elig['eligibilityName']?.toString() ?? ''));
      }
    }

    return words;
  }

  Set<String> _extractAllJobWords(Map<String, dynamic> job) {
    Set<String> words = {};
    words.addAll(_tokenize(job['title']?.toString() ?? ''));
    words.addAll(_tokenize(job['company']?.toString() ?? ''));
    words.addAll(_tokenize(job['description']?.toString() ?? ''));
    words.addAll(_tokenize(job['requirements']?.toString() ?? ''));
    
    final skills = _safeGetList(job['requiredSkills']);
    for (var skill in skills) {
      words.addAll(_tokenize(skill?.toString() ?? ''));
    }
    
    words.addAll(_tokenize(job['location']?.toString() ?? ''));
    words.addAll(_tokenize(job['employmentType']?.toString() ?? ''));
    return words;
  }

  String _normalizeText(String text) {
    return text.toLowerCase().trim().replaceAll(RegExp(r'[^\w\s]'), ' ');
  }

  Set<String> _tokenize(String text) {
    if (text.isEmpty) return {};
    final stopWords = {
      'the', 'a', 'an', 'and', 'or', 'but', 'in', 'on', 'at', 'to', 'for',
      'of', 'with', 'by', 'from', 'as', 'is', 'was', 'are', 'were', 'been',
      'be', 'have', 'has', 'had', 'do', 'does', 'did', 'will', 'would',
      'could', 'should', 'may', 'might', 'must', 'can', 'this', 'that',
      'these', 'those', 'i', 'you', 'he', 'she', 'it', 'we', 'they',
    };
    return _normalizeText(text)
        .split(RegExp(r'\s+'))
        .where((w) => w.length > 2 && !stopWords.contains(w))
        .toSet();
  }

  // ============================================================
  // JOB APPLICATION
  // ============================================================

  Future<void> _applyForJob(String jobId) async {
    if (currentUser == null) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('You must be logged in to apply.')));
      return;
    }

    if (appliedJobIds.contains(jobId)) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('You have already applied to this job.')));
      return;
    }

    try {
      final userDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(currentUser!.uid)
          .get();
      final userData = userDoc.data();

      if (userData == null || userData['resumeUrl'] == null || userData['resumeUrl'].isEmpty) {
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Resume Required'),
            content: const Text('Please upload your resume before applying for jobs.'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
              TextButton(
                onPressed: () {
                  Navigator.pop(context);
                  Navigator.pushNamed(context, '/profile');
                },
                child: const Text('Upload Resume'),
              ),
            ],
          ),
        );
        return;
      }

      final appliedAt = Timestamp.now();

      await FirebaseFirestore.instance
          .collection('users')
          .doc(currentUser!.uid)
          .update({
        'appliedJobs': FieldValue.arrayUnion([{'jobId': jobId, 'appliedAt': appliedAt}])
      });

      await FirebaseFirestore.instance.collection('jobs').doc(jobId).update({
        'applicants': FieldValue.arrayUnion([{
          'uid': currentUser!.uid,
          'fullName': userData['fullName'] ?? '',
          'email': userData['email'] ?? '',
          'resumeUrl': userData['resumeUrl'],
          'appliedAt': appliedAt,
        }]),
      });

      setState(() => appliedJobIds.add(jobId));
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Applied successfully!')));
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to apply: $e')));
    }
  }

  // ============================================================
  // UI COMPONENTS
  // ============================================================

  void _showJobDetailsDialog(Map<String, dynamic> data, String jobId) {
    final matchData = jobMatchDetails[jobId] ?? calculateComprehensiveMatch(data);
    final breakdown = matchData['breakdown'] as Map<String, dynamic>? ?? {};
    
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: Row(
            children: [
              const Icon(Icons.work_outline, color: Colors.blue),
              const SizedBox(width: 10),
              Expanded(child: Text(data['title'] ?? 'Job Details',
                  style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold))),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: _getMatchColor(matchData['totalScore'] ?? 0),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text('${(matchData['totalScore'] ?? 0).toStringAsFixed(0)}%',
                    style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold)),
              ),
            ],
          ),
          content: SizedBox(
            width: MediaQuery.of(context).size.width * 0.5,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _detailRow(Icons.business, 'Company', data['company']),
                  _detailRow(Icons.location_on, 'Location', data['location']),
                  _detailRow(Icons.school, 'Education', data['educationLevel']),
                  _detailRow(Icons.work, 'Employment Type', data['employmentType']),
                  if (data['salaryMin'] != null && data['salaryMax'] != null)
                    _detailRow(Icons.payments, 'Salary', '₱${data['salaryMin']} - ₱${data['salaryMax']}'),
                  const Divider(),

                  // Algorithm Breakdown
                  if (userProfile != null) ...[
                    const Text('🤖 AI Match Analysis', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 12),
                    
                    // TF-IDF Score
                    _buildScoreCard(
                      'TF-IDF Cosine Similarity',
                      breakdown['tfidf']?['score'] ?? 0,
                      breakdown['tfidf']?['weight'] ?? '35%',
                      Icons.text_fields,
                      Colors.blue,
                      'Measures how similar your profile keywords are to job requirements',
                    ),
                    
                    // Rule-Based Score
                    _buildScoreCard(
                      'Rule-Based Filtering',
                      breakdown['ruleBased']?['score'] ?? 0,
                      breakdown['ruleBased']?['weight'] ?? '30%',
                      Icons.rule,
                      Colors.green,
                      'Checks education, location, employment type, and program eligibility',
                      matchedRules: breakdown['ruleBased']?['matchedRules'],
                      unmatchedRules: breakdown['ruleBased']?['unmatchedRules'],
                    ),
                    
                    // Clustering Score
                    _buildScoreCard(
                      'Career Level Clustering',
                      breakdown['clustering']?['score'] ?? 0,
                      breakdown['clustering']?['weight'] ?? '20%',
                      Icons.hub,
                      Colors.purple,
                      'Your cluster: ${breakdown['clustering']?['userCluster'] ?? 'N/A'}\nJob cluster: ${breakdown['clustering']?['jobCluster'] ?? 'N/A'}',
                    ),
                    
                    // Sentiment Score
                    _buildScoreCard(
                      'VADER Sentiment Analysis',
                      breakdown['sentiment']?['score'] ?? 0,
                      breakdown['sentiment']?['weight'] ?? '15%',
                      Icons.sentiment_satisfied,
                      Colors.orange,
                      'Job tone: ${breakdown['sentiment']?['sentiment'] ?? 'Neutral'}',
                      positiveWords: breakdown['sentiment']?['positiveWords'],
                    ),
                    
                    const Divider(),
                  ],

                  // Program badges
                  if (data['isPWD'] == true || data['isSPES'] == true || data['isMIP'] == true) ...[
                    const Text('Programs:', style: TextStyle(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      children: [
                        if (data['isPWD'] == true) _programBadge('PWD', Icons.accessible, Colors.purple),
                        if (data['isSPES'] == true) _programBadge('SPES', Icons.school, Colors.orange),
                        if (data['isMIP'] == true) _programBadge('MIP', Icons.groups, Colors.teal),
                      ],
                    ),
                    const Divider(),
                  ],

                  const Text('Description:', style: TextStyle(fontWeight: FontWeight.bold)),
                  Text(data['description'] ?? ''),
                  const SizedBox(height: 12),
                  const Text('Requirements:', style: TextStyle(fontWeight: FontWeight.bold)),
                  Text(data['requirements'] ?? ''),
                  const SizedBox(height: 12),
                  const Text('Required Skills:', style: TextStyle(fontWeight: FontWeight.bold)),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: (_safeGetList(data['requiredSkills']))
                        .map((skill) => Chip(
                              label: Text(skill.toString(), style: const TextStyle(fontSize: 12)),
                              backgroundColor: Colors.blue.shade50,
                            ))
                        .toList(),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton.icon(
              onPressed: () => Navigator.pop(context),
              icon: const Icon(Icons.close, color: Colors.grey),
              label: const Text('Close', style: TextStyle(color: Colors.grey)),
            ),
          ],
        );
      },
    );
  }

  Widget _buildScoreCard(String title, double score, String weight, IconData icon, Color color, String description,
      {List<dynamic>? matchedRules, List<dynamic>? unmatchedRules, List<dynamic>? positiveWords}) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withOpacity(0.05),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: color, size: 20),
              const SizedBox(width: 8),
              Expanded(child: Text(title, style: TextStyle(fontWeight: FontWeight.bold, color: color))),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(color: color.withOpacity(0.2), borderRadius: BorderRadius.circular(8)),
                child: Text('${score.toStringAsFixed(1)}%', style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 12)),
              ),
              const SizedBox(width: 4),
              Text('($weight)', style: const TextStyle(fontSize: 11, color: Colors.grey)),
            ],
          ),
          const SizedBox(height: 4),
          Text(description, style: const TextStyle(fontSize: 12, color: Colors.black54)),
          if (matchedRules != null && matchedRules.isNotEmpty) ...[
            const SizedBox(height: 6),
            Wrap(
              spacing: 4,
              runSpacing: 4,
              children: matchedRules.take(5).map((r) => Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(color: Colors.green.shade100, borderRadius: BorderRadius.circular(4)),
                child: Text('✓ $r', style: const TextStyle(fontSize: 10, color: Colors.green)),
              )).toList(),
            ),
          ],
          if (positiveWords != null && positiveWords.isNotEmpty) ...[
            const SizedBox(height: 6),
            Wrap(
              spacing: 4,
              children: positiveWords.take(8).map((w) => Text('+$w', style: TextStyle(fontSize: 10, color: Colors.green.shade700))).toList(),
            ),
          ],
        ],
      ),
    );
  }

  Widget _detailRow(IconData icon, String label, String? value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(icon, size: 18, color: Colors.grey),
          const SizedBox(width: 8),
          Text('$label: ', style: const TextStyle(fontWeight: FontWeight.w500)),
          Expanded(child: Text(value ?? 'Not specified')),
        ],
      ),
    );
  }

  Widget _programBadge(String label, IconData icon, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withOpacity(0.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 4),
          Text(label, style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 12)),
        ],
      ),
    );
  }

  Color _getMatchColor(double score) {
    if (score >= 80) return Colors.green;
    if (score >= 60) return Colors.lightGreen;
    if (score >= 40) return Colors.orange;
    return Colors.grey;
  }

  @override
  Widget build(BuildContext context) {
    return MainScaffold(
      child: Stack(
        children: [
          Container(
            decoration: const BoxDecoration(
              image: DecorationImage(
                image: AssetImage('assets/images/homebackground.png'),
                fit: BoxFit.cover,
                alignment: Alignment.topCenter,
              ),
            ),
          ),
          Container(color: Colors.black.withOpacity(0.4)),
          SingleChildScrollView(
            child: Column(
              children: [
                Container(
                  height: 200,
                  width: double.infinity,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [Colors.blueAccent, Colors.blue[900]!],
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                    ),
                  ),
                  child: const Center(
                    child: Padding(
                      padding: EdgeInsets.symmetric(horizontal: 24.0),
                      child: Text(
                        "Find Your Perfect Job Match!\n\nPowered by TF-IDF, Rule-Based Filtering, K-Means Clustering & VADER Sentiment Analysis",
                        style: TextStyle(fontSize: 18, color: Colors.white, fontWeight: FontWeight.bold, height: 1.5),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
                ),
                Center(
                  child: Container(
                    constraints: const BoxConstraints(maxWidth: 1100),
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      children: [
                        const SizedBox(height: 16),
                        if (userProfile != null)
                          Container(
                            padding: const EdgeInsets.all(12),
                            margin: const EdgeInsets.only(bottom: 16),
                            decoration: BoxDecoration(
                              color: Colors.blue.shade700,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Row(
                              children: [
                                const Icon(Icons.auto_awesome, color: Colors.yellow),
                                const SizedBox(width: 8),
                                const Expanded(
                                  child: Text(
                                    'AI Job Matching: TF-IDF (35%) + Rules (30%) + Clustering (20%) + Sentiment (15%)',
                                    style: TextStyle(color: Colors.white, fontSize: 12),
                                  ),
                                ),
                                Switch(
                                  value: _showRecommended,
                                  onChanged: (v) => setState(() => _showRecommended = v),
                                  activeColor: Colors.yellow,
                                ),
                              ],
                            ),
                          ),
                        _buildFilters(),
                        const Divider(color: Colors.white54),
                        _buildJobListings(),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilters() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('Find jobs here', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.blue)),
        const SizedBox(height: 4),
        const Text('Search by position, company, skills, or use filters below.', style: TextStyle(fontSize: 14, color: Colors.white)),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _searchController,
                decoration: InputDecoration(
                  hintText: 'Search jobs...',
                  prefixIcon: const Icon(Icons.search),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                  filled: true,
                  fillColor: Colors.white,
                ),
                onChanged: (v) => setState(() {}),
              ),
            ),
            const SizedBox(width: 12),
            _buildFilterDropdown(barangays, _selectedBarangay ?? 'Barangays', (v) => setState(() => _selectedBarangay = v)),
          ],
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            _buildFilterDropdown(employmentTypes, _selectedEmploymentType ?? 'Employment Type', (v) => setState(() => _selectedEmploymentType = v)),
            _buildFilterDropdown(educationLevels, _selectedEducationLevel ?? 'Education Level', (v) => setState(() => _selectedEducationLevel = v)),
            _buildProgramCheckbox('PWD', _pwdOnly, (v) => setState(() => _pwdOnly = v!), Icons.accessible, Colors.purple),
            _buildProgramCheckbox('SPES', _spesOnly, (v) => setState(() => _spesOnly = v!), Icons.school, Colors.orange),
            _buildProgramCheckbox('MIP', _mipOnly, (v) => setState(() => _mipOnly = v!), Icons.groups, Colors.teal),
          ],
        ),
      ],
    );
  }

  Widget _buildFilterDropdown(List<String> items, String value, Function(String?) onChanged) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 180),
      child: DropdownButtonFormField<String>(
        value: value,
        decoration: InputDecoration(
          filled: true,
          fillColor: Colors.white,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        ),
        items: items.map((e) => DropdownMenuItem(value: e, child: Text(e, style: const TextStyle(fontSize: 13)))).toList(),
        onChanged: onChanged,
      ),
    );
  }

  Widget _buildProgramCheckbox(String label, bool value, Function(bool?) onChanged, IconData icon, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: value ? color.withOpacity(0.2) : Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: value ? color : Colors.grey.shade300),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Checkbox(value: value, onChanged: onChanged, activeColor: color, visualDensity: VisualDensity.compact),
          Icon(icon, size: 18, color: value ? color : Colors.grey),
          const SizedBox(width: 4),
          Text(label, style: TextStyle(fontSize: 13, color: value ? color : Colors.black87, fontWeight: value ? FontWeight.bold : FontWeight.normal)),
        ],
      ),
    );
  }

  Widget _buildJobListings() {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance.collection('jobs').orderBy('postedDate', descending: true).snapshots(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());

        var docs = snapshot.data!.docs.where((doc) {
          final data = doc.data() as Map<String, dynamic>;
          final keyword = _searchController.text.toLowerCase();
          final allContent = '${data['title'] ?? ''}${data['company'] ?? ''}${data['description'] ?? ''}${data['requirements'] ?? ''}${(_safeGetList(data['requiredSkills'])).join(',')}'.toLowerCase();

          return (keyword.isEmpty || allContent.contains(keyword)) &&
              (_selectedBarangay == null || _selectedBarangay == 'Barangays' || (data['location'] ?? '').toString().toLowerCase() == _selectedBarangay!.toLowerCase()) &&
              (_selectedEmploymentType == null || _selectedEmploymentType == 'Employment Type' || (data['employmentType'] ?? '').toString().toLowerCase() == _selectedEmploymentType!.toLowerCase()) &&
              (_selectedEducationLevel == null || _selectedEducationLevel == 'Education Level' || (data['educationLevel'] ?? '').toString().toLowerCase() == _selectedEducationLevel!.toLowerCase()) &&
              (!_pwdOnly || data['isPWD'] == true) &&
              (!_spesOnly || data['isSPES'] == true) &&
              (!_mipOnly || data['isMIP'] == true);
        }).toList();

        // Calculate IDF and match scores
        if (_showRecommended && userProfile != null) {
          _allJobs = docs.map((d) => d.data() as Map<String, dynamic>).toList();
          _calculateIDF(_allJobs);

          for (var doc in docs) {
            final data = doc.data() as Map<String, dynamic>;
            final matchResult = calculateComprehensiveMatch(data);
            jobMatchScores[doc.id] = matchResult['totalScore'] as double;
            jobMatchDetails[doc.id] = matchResult;
          }
          docs.sort((a, b) => (jobMatchScores[b.id] ?? 0).compareTo(jobMatchScores[a.id] ?? 0));
        }

        if (docs.isEmpty) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(40),
              child: Text('No jobs found matching your criteria.', style: TextStyle(color: Colors.white, fontSize: 16)),
            ),
          );
        }

        return Column(children: docs.map((doc) {
          final data = doc.data() as Map<String, dynamic>;
          return _buildJobCard(data, doc.id, jobMatchScores[doc.id] ?? 0, appliedJobIds.contains(doc.id));
        }).toList());
      },
    );
  }

  Widget _buildJobCard(Map<String, dynamic> data, String jobId, double matchScore, bool alreadyApplied) {
    final colors = [Colors.blue, Colors.green, Colors.orange, Colors.purple, Colors.red];
    final bgColor = colors[jobId.hashCode % colors.length];
    final initials = (data['company']?.toString().isNotEmpty == true) ? data['company'].toString().trim()[0].toUpperCase() : '?';

    return InkWell(
      onTap: () => _showJobDetailsDialog(data, jobId),
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 8),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.grey.shade300),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 60,
              height: 60,
              decoration: BoxDecoration(
                color: bgColor.withOpacity(0.8),
                borderRadius: BorderRadius.circular(8),
                image: (data['logoUrl']?.toString().isNotEmpty == true)
                    ? DecorationImage(image: NetworkImage(data['logoUrl']), fit: BoxFit.cover)
                    : null,
              ),
              child: (data['logoUrl'] == null || data['logoUrl'].toString().isEmpty)
                  ? Center(child: Text(initials, style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold)))
                  : null,
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(child: Text(data['title'] ?? '', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.blue))),
                      if (_showRecommended && userProfile != null && matchScore > 0)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(color: _getMatchColor(matchScore), borderRadius: BorderRadius.circular(12)),
                          child: Text('${matchScore.toStringAsFixed(0)}%', style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold)),
                        ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(data['company'] ?? '', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      const Icon(Icons.location_on, size: 16, color: Colors.grey),
                      const SizedBox(width: 4),
                      Text(data['location'] ?? 'Not specified', style: const TextStyle(fontSize: 13, color: Colors.black54)),
                      const SizedBox(width: 12),
                      const Icon(Icons.school, size: 16, color: Colors.grey),
                      const SizedBox(width: 4),
                      Text(data['educationLevel'] ?? 'Not specified', style: const TextStyle(fontSize: 13, color: Colors.black54)),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    children: [
                      if (data['isPWD'] == true) _smallBadge('PWD', Colors.purple),
                      if (data['isSPES'] == true) _smallBadge('SPES', Colors.orange),
                      if (data['isMIP'] == true) _smallBadge('MIP', Colors.teal),
                    ],
                  ),
                ],
              ),
            ),
            ElevatedButton(
              onPressed: alreadyApplied ? null : () => _applyForJob(jobId),
              style: ElevatedButton.styleFrom(
                backgroundColor: alreadyApplied ? Colors.grey : Colors.blue,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              child: Text(alreadyApplied ? 'Applied' : 'Apply', style: const TextStyle(color: Colors.white)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _smallBadge(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withOpacity(0.5)),
      ),
      child: Text(label, style: TextStyle(fontSize: 10, color: color, fontWeight: FontWeight.bold)),
    );
  }
}