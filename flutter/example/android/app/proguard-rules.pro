# flutter_local_notifications persists scheduled notifications via Gson. R8
# strips the generic type signatures Gson relies on, which surfaces at runtime
# as "java.lang.RuntimeException: Missing type parameter." when a second
# reminder is scheduled (it deserializes the stored list). Keep the plugin's
# model classes, Gson's TypeToken machinery, and the generic Signature
# attribute so deserialization works.
-keep class com.dexterous.flutterlocalnotifications.** { *; }
-keep class com.google.gson.** { *; }
-keep class * extends com.google.gson.reflect.TypeToken
-keep class * extends com.google.gson.TypeAdapter
-keepattributes Signature
-keepattributes *Annotation*
-keepattributes InnerClasses,EnclosingMethod
