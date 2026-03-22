# **Technical Specification and Judicial Implementation of the UYAP Document Format (.udf): A Comprehensive Forensic and Architectural Analysis**

The digital transformation of the Turkish judicial system is anchored in the National Judiciary Network Project, known as UYAP (Ulusal Yargı Ağı Bilişim Sistemi). At the center of this technological ecosystem is a specialized document format identified by the.udf extension. This file format is not merely a vehicle for text but a sophisticated container designed to ensure the integrity, authenticity, and non-repudiation of judicial documents within a centralized legal database.1 While the extension ".udf" frequently causes technical confusion with the ISO-standard Universal Disk Format used in optical media, the UYAP.udf is a proprietary specification developed by the Turkish Ministry of Justice's General Directorate of Information Technology.1 This report provides an exhaustive examination of the.udf architecture, its cryptographic foundations, the software environment required for its management, and its critical role in the Turkish legal framework.

## **Architectural Differentiation and the Naming Conflict**

A primary hurdle in the technical analysis of UYAP files is the nomenclature overlap with the Universal Disk Format (UDF). The OSTA-defined UDF is a file system standard, specifically ISO/IEC 13346, designed for high-capacity optical storage and incremental packet writing on media such as DVD-RW and Blu-ray.4 This standard operates at the volume and block level, facilitating data interchange across various operating systems like Windows and Macintosh.6

In contrast, the UYAP.udf is an application-layer document format.1 It does not function as a file system or a disk image; rather, it is a document encapsulation format similar to Adobe’s PDF or Microsoft’s DOCX, but tailored specifically for the Turkish judicial infrastructure.1 Forensic analysts must distinguish between these two entities, as tools designed for one (such as disk mounting utilities) are entirely incompatible with the other.8

| Characteristic | OSTA Universal Disk Format (UDF) | UYAP Document Format (.udf) |
| :---- | :---- | :---- |
| **Origin** | Optical Storage Technology Association | Turkish Ministry of Justice |
| **Standardization** | ISO/IEC 13346 / ECMA-167 | Proprietary Judicial Specification |
| **Primary Level** | File System / Block Level | Document / Content Level |
| **Internal Logic** | Virtual Allocation Table (VAT) | Compressed XML Container |
| **Security** | Minimal (Media Level) | Integrated CAdES Digital Signatures |
| **Primary Platform** | Cross-platform (OS Driver level) | UYAP Doküman Editörü (Java-based) |

The UYAP format's popularity rating is characterized as "low" in general computing contexts but possesses a "critical" saturation within the Turkish legal and public sectors.1 It is the mandatory format for attorneys, judges, and court personnel, serving as the official record for pleadings, court minutes, and verdicts.2

## **Internal Structure and Containerization**

The UYAP.udf file is an encapsulated archive, utilizing ZIP compression to package multiple data streams into a single file.10 Forensic renaming of a.udf file to a.zip extension allows for the extraction and examination of its core constituents.8 The internal hierarchy typically consists of three primary components that define the document's content, administrative metadata, and cryptographic identity.11

## **The Core Constituents of the.udf Archive**

The internal manifest of a.udf file reveals a structured approach to document management. By separating content from signatures and metadata, the Ministry of Justice ensures that the document's textual data can be processed independently of its security layer while maintaining a rigid link between the two.10

1. **content.xml**: This is the primary data payload. It contains the document text, formatting instructions, and structural markers.11 The XML uses a specific schema where textual data is often wrapped in CData (Character Data) sections to prevent special characters from breaking the XML parser.10  
2. **documentproperties.xml**: This file stores administrative metadata required for the UYAP validation system.11 Key data points include the unique "doğrulama kodu" (verification code), which allows parties to verify the document's authenticity on the public UYAP portal, and the registry information of the individual who created the document.2  
3. **sign.sgn**: This is a detached digital signature file.11 It encapsulates the cryptographic hash of the content, signed by the author's private key via a secure hardware token.9

In documents containing complex layouts or embedded assets, an "images" directory may be present within the ZIP container to hold binary data referenced by the content.xml.5

## **XML Schema and Semantic Tagging**

The content.xml file follows a proprietary schema designed to reflect the hierarchical nature of judicial documents.15 Unlike standard HTML or basic XML, the UYAP tags are semantically aligned with Turkish legal terminology.15

* \<evrak\>: The root element encapsulating the entire judicial instrument.15  
* \<icerik\>: The parent tag for the primary textual body of the document.15  
* \<paragraf\>: Defines individual text blocks.15 Attributes within this tag specify alignment (e.g., "Sola Yasla" for left-aligned) and formatting.15  
* \<tablo\>: Used for representing structured data, such as parties in a lawsuit or financial calculations in a court decree.5

The use of XML allows for a clear separation of data and presentation, which facilitates the UYAP Editor's ability to export.udf files into more universal formats like PDF, RTF, and ODT.15 However, the specific interpretation of these tags is heavily dependent on the rendering engine of the official editor, which handles complex elements like page headers, footers, and institutional logos.15

## **Cryptographic Framework and Electronic Signatures**

The most significant aspect of the.udf format is its integration with the Turkish Electronic Signature Law (No. 5070).9 A.udf document is not considered legally binding in the UYAP system unless it contains a valid "secure electronic signature".2

## **The sign.sgn File and CAdES Standards**

The sign.sgn file is typically a PKCS\#7 / CMS (Cryptographic Message Syntax) object following the CAdES (CMS Advanced Electronic Signatures) standard.17 CAdES is chosen for judicial applications because of its support for long-term validity, which is essential for court records that must be verifiable decades after their creation.22

The UYAP infrastructure utilizes several profiles of the CAdES standard to meet varying security and longevity requirements:

| Signature Profile | Description | Use Case |
| :---- | :---- | :---- |
| **CAdES-BES** | Basic Electronic Signature; includes signed attributes but lacks a timestamp. | Short-term documents with immediate processing. 22 |
| **CAdES-T** | Signature with a trusted timestamp from an authorized service provider. | Guarantees the signature existed before a specific time. 22 |
| **CAdES-X-LONG** | Extended Long-Term Signature; includes all validation data (certificates/CRLs). | The standard for UYAP; allows offline verification without external CA lookups. 22 |
| **CAdES-EPES** | Explicit Policy Electronic Signature; includes a signature policy identifier. | Used when specific judicial policies dictate the signing process. 22 |

The signature verification process relies on the Public Key Infrastructure (PKI) managed by the Information and Communication Technologies Authority (BTK) and the National Public Key Infrastructure Center (Kamu SM).15 The verification of a.udf signature involves recalculating the hash of the content.xml and comparing it with the decrypted hash from the sign.sgn using the signer's public key.23 If the document has been tampered with—even by a single bit—the hashes will not match, and the UYAP Editor will flag the document as invalid.23

## **Legal Admissibility and the Paperless Mandate**

Under Law No. 5070 and the Code of Civil Procedure (HMK), electronically signed.udf documents are considered "original" legal instruments.9 This creates a "paperless" mandate where physical copies are relegated to the status of mere derivatives.9 If a discrepancy occurs between a physical printout and the.udf file stored in the UYAP database, the electronically signed file is the legally definitive version.9

This framework ensures:

* **Integrity**: The document cannot be altered after signing without detection.23  
* **Non-Repudiation**: The signer cannot deny having signed the document, as the signature requires a unique hardware token and a PIN known only to the holder.9  
* **Authenticity**: The identity of the signer (e.g., a specific judge or attorney) is verified through their Qualified Electronic Certificate.9

## **The Software Ecosystem: UYAP Doküman Editörü**

To interact with.udf files, users must utilize the official UYAP Doküman Editörü (UYAP Document Editor), developed by the Ministry of Justice.3 The editor is a Java-based application, chosen for its cross-platform capabilities, allowing the Turkish government to deploy the same software on Windows, macOS, and Linux (specifically the domestic Pardus distribution).15

## **Technical Requirements and Environment Configuration**

The reliance on Java (specifically the Java Runtime Environment or JRE) is the primary source of technical support issues for UYAP users.15 The editor is optimized for 32-bit Java 8, and mismatches in the Java version often lead to "NullPointerException" errors or failure to initialize the e-signature smart card drivers.18

| Platform | Installer Type | Key Requirements | Path for Config Files |
| :---- | :---- | :---- | :---- |
| **Windows** | .exe /.msi | 32-bit Java JRE, Smart Card Drivers | C:\\Users\\\[User\]\\.uki 15 |
| **macOS** | .dmg /.zip | Java for Mac, Admin Privileges | /Users/\[User\]/.uki 27 |
| **Linux** | .zip /.deb | Java, cups-bsd package for printing | \~/.uki 20 |

A critical troubleshooting procedure for the editor involves the .uki directory.27 This hidden folder stores local configuration files:

* acilisdegerleri.xml: Stores initial window states and versioning data.27  
* tercihler.xml: Stores user-specific preferences and editor settings.27  
* lastOpened.xml: Maintains a history of recently accessed documents.27

If the editor fails to launch or behaves erratically, users are instructed to delete these XML files to reset the application to its default state.27 This mechanism highlights the editor's reliance on local state management despite its primary role as a gateway to a centralized judicial cloud.2

## **Mobile and Browser-Based Limitations**

While the desktop editor provides full word-processing capabilities, the mobile versions available for Android and iOS are primarily "readers".5 These apps allow citizens and attorneys to view case files on the go but often lack the sophisticated formatting and signing tools required for document creation.5 This limitation has led to a demand for mobile "converters" that can transform standard office formats into the.udf structure, though security protocols currently limit the official support for such tools.5

## **Programmatic Extraction and Data Interoperability**

For legal technology developers and data scientists, the closed nature of the.udf format presents a barrier to large-scale analysis. However, because the format is fundamentally a ZIP archive containing XML, it is possible to bypass the official editor for automated data extraction.10

## **Automated Extraction with Python**

The Python ecosystem provides the necessary libraries to deconstruct.udf files and extract their textual content.10 The process typically involves using the zipfile module to extract content.xml and then applying an XML parser like xml.etree.ElementTree or lxml to navigate the document tree.12

A conceptual implementation for a.udf-to-text parser follows this logic:

1. **Archive Access**: Open the.udf using zipfile.ZipFile(file, 'r').12  
2. **Member Extraction**: Read the content.xml stream into memory.13  
3. **Namespace Management**: UYAP XML files may use specific namespaces that must be handled to locate tags like \<icerik\> or \<paragraf\>.16  
4. **CData Decoding**: Text within the tags must be unescaped if it is stored in CData blocks.10  
5. **Reconstruction**: Concatenate the text from individual paragraph tags into a coherent document stream.15

This programmatic approach is essential for applications such as:

* **Legal Analytics**: Searching through thousands of case files for specific precedents or patterns.32  
* **Case Management Systems**: Automatically ingesting court documents into a law firm's internal database.2  
* **AI Training**: Using judicial text for training Large Language Models (LLMs) specialized in Turkish law.35

## **Third-Party Toolkits and Risks**

Several unofficial tools, such as the UDF-Toolkit and UdfParser found on GitHub, provide pre-built scripts for these tasks.10 While these tools increase efficiency, they also introduce security risks. Judicial documents often contain sensitive personal data protected by the Personal Data Protection Law (KVKK).2 Uploading.udf files to third-party "online converters" is highly discouraged, as the conversion process exposes the unencrypted contents of the content.xml to the service provider.3

## **Judicial Significance and the Digital Workflow**

The.udf format has reshaped the workflow of the Turkish legal profession.2 Its adoption has moved the judiciary toward a "digital-first" model, where the UYAP portal acts as the central repository for all legal proceedings.9

## **Interaction with the UYAP Portals**

Different user groups interact with.udf files through dedicated portals within the UYAP ecosystem.2

| Portal Name | Primary Users | Role in UDF Lifecycle |
| :---- | :---- | :---- |
| **Attorney Portal (Avukat Portalı)** | Attorneys | Uploading pleadings, downloading court records. 2 |
| **Citizen Portal (Vatandaş Portalı)** | Citizens / Parties | Viewing decision.udf files, monitoring case progress. 5 |
| **Institution Portal (Kurum Portalı)** | Legal entities / Banks | Managing high-volume litigation and debt collection. 9 |
| **Staff Portal (Personel Portalı)** | Judges / Clerks | Generating minutes, warrants, and verdicts. 2 |

The.udf format ensures that a document created by a judge in a remote court can be instantly viewed by an attorney in Istanbul with its legal validity intact.2 This eliminated the delays and costs associated with physical mail and manual filing.9

## **Integration with KEP and EYP**

In addition to the internal UYAP portals, the.udf format interacts with the Registered Electronic Mail (KEP) system.14 The e-Yazışma (Electronic Correspondence) standard, which uses the .eyp extension, often contains.udf documents as payloads.14 This integration allows for formal communication between judicial units and other government agencies while maintaining the cryptographic chain of trust established by the.udf signature.9

## **Troubleshooting and Forensic Recovery**

Digital forensic investigation of.udf files can yield evidence beyond the visible text. Because the format is a ZIP container, it inherits the forensic properties of archived data.8

## **Metadata and Forensic Traces**

The documentproperties.xml file is a primary target for forensic analysts.11 It provides a verifiable link between a digital file and the UYAP database through the "doğrulama kodu".2 This code allows an investigator to cross-reference a local file with the version on the Ministry of Justice servers, confirming whether the file is a genuine court document or a forgery.2

Furthermore, the e-signature within the sign.sgn file contains its own metadata, including the serial number of the smart card used and the exact time of signing provided by a Trusted Timestamping Authority (TSA).22 This provides a more reliable "time of creation" than the operating system's file metadata, which can be easily altered.23

## **Document Corruption and Structural Repair**

Files can become corrupted due to interrupted downloads or storage media failure.8 Since the structure is a ZIP archive, standard repair tools can sometimes recover the content.xml even if the overall archive is unreadable by the UYAP Editor.8

Forensic recovery steps for a corrupted.udf include:

1. **Signature Analysis**: Checking the ZIP file's magic bytes (50 4B 03 04\) at the start of the file.12  
2. **Archive Repair**: Using utilities like zip \-FF to reconstruct the central directory.12  
3. **Manual XML Parsing**: If the sign.sgn is intact but the content.xml is damaged, the document's legal validity is compromised, but the textual evidence may still be extractable for investigative purposes.8

## **Future Outlook: Web-Based Evolution and AI**

The UYAP infrastructure is moving toward a more decentralized and platform-independent model. The current reliance on a Java-based desktop application is seen as a bottleneck for accessibility.5

## **The Move to Browser-Based Editing**

Future iterations of the UYAP Document Editor are expected to be fully browser-integrated, utilizing web-based signing APIs that interact with the user's smart card through a small local agent rather than a full Java application.15 This would eliminate the common JRE versioning conflicts and allow for seamless document management within the Attorney and Citizen portals.15

## **AI-Enhanced Document Intelligence**

The structured nature of the.udf's XML data is ideal for integration with artificial intelligence.35 The Ministry of Justice has already begun exploring AI-assisted decision-making and legal research tools that can parse the semantic tags within.udf files to provide judges with relevant precedents and case summaries.35 The use of content.xml as a data source allows these AI models to process judicial text with high precision, as the structural tags (e.g., distinguishing a "defendant" from a "witness") provide a level of context that raw text lacks.10

## **Conclusion**

The UYAP.udf extension is a sophisticated and highly specialized file format that serves as the technological backbone of the Turkish judiciary.1 By combining ZIP-based containerization with XML-structured data and CAdES-compliant digital signatures, the format achieves a level of security and legal validity that surpasses traditional paper-based systems.9 While the naming collision with the Universal Disk Format and the technical dependencies on Java present challenges for the uninitiated, the.udf remains an essential instrument for the practice of law in Turkey.1 For legal professionals, developers, and forensic investigators, a deep understanding of the.udf format's architectural and cryptographic properties is critical for navigating the modern Turkish legal landscape.2

#### **Works cited**

1. UDF File Extension: What Is It & How To Open It? \- Solvusoft, accessed March 19, 2026, [https://www.solvusoft.com/en/file-extensions/file-extension-udf/](https://www.solvusoft.com/en/file-extensions/file-extension-udf/)  
2. .UDF Dosyaları ve UYAP Editör: Dava Dosyalarınızı Yönetin \- Avukat Ali DENİZ, accessed March 19, 2026, [https://www.alideniz.av.tr/udf-dosyalari-ve-uyap-editor/](https://www.alideniz.av.tr/udf-dosyalari-ve-uyap-editor/)  
3. UYAP UDF Dosyası Nasıl Açılır? Adım Adım Anlatım | İncehesap Blog, accessed March 19, 2026, [https://www.incehesap.com/blog/udf-dosyasi-nedir-nasil-acilir-uyap/](https://www.incehesap.com/blog/udf-dosyasi-nedir-nasil-acilir-uyap/)  
4. Universal Disk Format \- Wikipedia, accessed March 19, 2026, [https://en.wikipedia.org/wiki/Universal\_Disk\_Format](https://en.wikipedia.org/wiki/Universal_Disk_Format)  
5. Uyap Doküman Editör \- Apps on Google Play, accessed March 19, 2026, [https://play.google.com/store/apps/details?id=tr.gov.uyap.editor](https://play.google.com/store/apps/details?id=tr.gov.uyap.editor)  
6. What Is A Universal Disk Format (UDF) \- Indicative, accessed March 19, 2026, [https://www.indicative.com/resource/universal-disk-format-udf/](https://www.indicative.com/resource/universal-disk-format-udf/)  
7. Extract text from PDF File using Python \- GeeksforGeeks, accessed March 19, 2026, [https://www.geeksforgeeks.org/python/extract-text-from-pdf-file-using-python/](https://www.geeksforgeeks.org/python/extract-text-from-pdf-file-using-python/)  
8. What is a UDF File? \- Techcareer.net, accessed March 19, 2026, [https://www.techcareer.net/en/blog/udf-dosyasi-nedir](https://www.techcareer.net/en/blog/udf-dosyasi-nedir)  
9. Subject 03- National Judiciary Informatics System (UYAP) \- LegalTalks, accessed March 19, 2026, [https://www.legaltalks.com.tr/subject-03-national-judiciary-informatics-system-uyap/](https://www.legaltalks.com.tr/subject-03-national-judiciary-informatics-system-uyap/)  
10. mistih/UdfParser: Türkiye Cumhuriyeti Adalet Bakanlığı ... \- GitHub, accessed March 19, 2026, [https://github.com/mistih/UdfParser](https://github.com/mistih/UdfParser)  
11. Ücretsiz UYAP UDF Belge Görüntüleyici \- Leo Isikdogan, accessed March 19, 2026, [https://www.isikdogan.com/turkce-blog/ucretsiz-uyap-udf-belge-goruntuleyici.html](https://www.isikdogan.com/turkce-blog/ucretsiz-uyap-udf-belge-goruntuleyici.html)  
12. zipfile — Work with ZIP archives — Python 3.14.3 documentation, accessed March 19, 2026, [https://docs.python.org/3/library/zipfile.html](https://docs.python.org/3/library/zipfile.html)  
13. Working with ZIP Files in Python \- GeeksforGeeks, accessed March 19, 2026, [https://www.geeksforgeeks.org/python/working-zip-files-python/](https://www.geeksforgeeks.org/python/working-zip-files-python/)  
14. "EYP Dosyası ve Açılması" makalesinin özeti — YaÖzet \- Yandex, accessed March 19, 2026, [https://yandex.com.tr/yaozet/how\_to/eyp-dosyasi-ve-acilmasi-2oOX6UhN](https://yandex.com.tr/yaozet/how_to/eyp-dosyasi-ve-acilmasi-2oOX6UhN)  
15. Uyap Editör Yardım, accessed March 19, 2026, [https://uyap.gov.tr/Uyap-Editor-Yardim](https://uyap.gov.tr/Uyap-Editor-Yardim)  
16. ABAP Cloud \- Read XML \- Software-Heroes, accessed March 19, 2026, [https://software-heroes.com/en/blog/abap-cloud-read-xml](https://software-heroes.com/en/blog/abap-cloud-read-xml)  
17. "SGN Dosya Formatı ve Sorunları" makalesinin özeti — YaÖzet \- Yandex, accessed March 19, 2026, [https://yandex.com.tr/yaozet/how\_to/sgn-dosya-formati-ve-sorunlari-UDqFXpjp](https://yandex.com.tr/yaozet/how_to/sgn-dosya-formati-ve-sorunlari-UDqFXpjp)  
18. Java based text editor is not working while JDK is installed \- Stack Overflow, accessed March 19, 2026, [https://stackoverflow.com/questions/74424537/java-based-text-editor-is-not-working-while-jdk-is-installed](https://stackoverflow.com/questions/74424537/java-based-text-editor-is-not-working-while-jdk-is-installed)  
19. XML Technical Specifications \- Amazon AWS, accessed March 19, 2026, [https://klvg4oyd4j.execute-api.us-west-2.amazonaws.com/prod/PublicFiles/ee3072ab0d43456cb15a51f7d82c77a2/edf77d1b-3b38-44ba-af65-76146d7d0e50/XML-Technical-Specifications-v4-09238.pdf](https://klvg4oyd4j.execute-api.us-west-2.amazonaws.com/prod/PublicFiles/ee3072ab0d43456cb15a51f7d82c77a2/edf77d1b-3b38-44ba-af65-76146d7d0e50/XML-Technical-Specifications-v4-09238.pdf)  
20. Uyap Editör İndir \- Ücretsiz İndir \- Tamindir, accessed March 19, 2026, [https://www.tamindir.com/indir/uyap-editor/](https://www.tamindir.com/indir/uyap-editor/)  
21. Signature Validation \[e-İmza Teknolojileri Test Suit e-Signature Technologies Test Suite \] \- Kamu SM, accessed March 19, 2026, [https://yazilim.kamusm.gov.tr/eit-wiki/doku.php?id=en:imza\_dogrulama](https://yazilim.kamusm.gov.tr/eit-wiki/doku.php?id=en:imza_dogrulama)  
22. en:esya:eimza:tipler \[ESYA\] \- Signature Types \- Kamu SM, accessed March 19, 2026, [https://yazilim.kamusm.gov.tr/esya-api/doku.php?id=en:esya:eimza:tipler](https://yazilim.kamusm.gov.tr/esya-api/doku.php?id=en:esya:eimza:tipler)  
23. How to verify if a digital signature is authentic? \- eSignGlobal, accessed March 19, 2026, [https://www.esignglobal.com/blog/how-to-verify-digital-signature-authentic](https://www.esignglobal.com/blog/how-to-verify-digital-signature-authentic)  
24. Do you know how to validate a digital signature? \- CertiSur, accessed March 19, 2026, [https://www.certisur.com/en/news/do-you-know-how-to-validate-a-digital-signature/](https://www.certisur.com/en/news/do-you-know-how-to-validate-a-digital-signature/)  
25. How to Open a UDF File, How to Open a File with the UDF Extension \- YouTube, accessed March 19, 2026, [https://www.youtube.com/watch?v=A6iY9szYxIw](https://www.youtube.com/watch?v=A6iY9szYxIw)  
26. How to Verify an Electronic Signature (A Guide for Secure eSigning) \- Xodo Sign, accessed March 19, 2026, [https://eversign.com/blog/how-to-tell-if-a-signature-is-real](https://eversign.com/blog/how-to-tell-if-a-signature-is-real)  
27. UYAP Editör \- UYAP Bilişim Sistemi, accessed March 19, 2026, [https://uyap.gov.tr/uyap-editor](https://uyap.gov.tr/uyap-editor)  
28. UDF Dosyası Nasıl Açılır? | Güncel UYAP Editör Rehberi \- KG Hukuk Bürosu, accessed March 19, 2026, [https://kghukuk.av.tr/udf-dosyasi-nasil-acilir/](https://kghukuk.av.tr/udf-dosyasi-nasil-acilir/)  
29. Uyap Doküman Editör \- App Store \- Apple, accessed March 19, 2026, [https://apps.apple.com/us/app/uyap-dok%C3%BCman-edit%C3%B6r/id1481849944](https://apps.apple.com/us/app/uyap-dok%C3%BCman-edit%C3%B6r/id1481849944)  
30. Extracting text from XML using python \- Stack Overflow, accessed March 19, 2026, [https://stackoverflow.com/questions/7691514/extracting-text-from-xml-using-python](https://stackoverflow.com/questions/7691514/extracting-text-from-xml-using-python)  
31. Solved: UDF to add xml namespace tag \- SAP Community, accessed March 19, 2026, [https://community.sap.com/t5/technology-q-a/udf-to-add-xml-namespace-tag/qaq-p/5097044](https://community.sap.com/t5/technology-q-a/udf-to-add-xml-namespace-tag/qaq-p/5097044)  
32. How to Parse Multiple XML Files in Python and Extract Specific Text \- YouTube, accessed March 19, 2026, [https://www.youtube.com/watch?v=ZjPn3gbQu-o](https://www.youtube.com/watch?v=ZjPn3gbQu-o)  
33. Extract Text from XML in Python using REST API \- GroupDocs Cloud, accessed March 19, 2026, [https://blog.groupdocs.cloud/parser/extract-text-from-xml-in-python-using-rest-api/](https://blog.groupdocs.cloud/parser/extract-text-from-xml-in-python-using-rest-api/)  
34. PDF extraction with use of python script \- Studio \- UiPath Community Forum, accessed March 19, 2026, [https://forum.uipath.com/t/pdf-extraction-with-use-of-python-script/4985848](https://forum.uipath.com/t/pdf-extraction-with-use-of-python-script/4985848)  
35. Best way to extract text from PDF docs for finetuning models? : r/LocalLLaMA \- Reddit, accessed March 19, 2026, [https://www.reddit.com/r/LocalLLaMA/comments/1502uc3/best\_way\_to\_extract\_text\_from\_pdf\_docs\_for/](https://www.reddit.com/r/LocalLLaMA/comments/1502uc3/best_way_to_extract_text_from_pdf_docs_for/)  
36. Introducing Kreuzberg: A Simple, Modern Library for PDF and Document Text Extraction in Python \- Reddit, accessed March 19, 2026, [https://www.reddit.com/r/Python/comments/1if3axy/introducing\_kreuzberg\_a\_simple\_modern\_library\_for/](https://www.reddit.com/r/Python/comments/1if3axy/introducing_kreuzberg_a_simple_modern_library_for/)  
37. saidsurucu/UDF-Toolkit: UYAP UDF dosya formatı ile ilgili ... \- GitHub, accessed March 19, 2026, [https://github.com/saidsurucu/UDF-Toolkit](https://github.com/saidsurucu/UDF-Toolkit)  
38. Opening Uyap Files UDF Files Without Program \- YouTube, accessed March 19, 2026, [https://www.youtube.com/watch?v=iZrR52Hsf9g](https://www.youtube.com/watch?v=iZrR52Hsf9g)  
39. UYAP E-İmza \- UYAP Bilişim Sistemi, accessed March 19, 2026, [https://uyap.gov.tr/uyap-eimza](https://uyap.gov.tr/uyap-eimza)